// SPDX-License-Identifier: MIT
import Testing
import Foundation
import ArgumentParser
@testable import StackroomImportCLI

@Suite("Anomaly fixture skip behavior")
struct AnomalyFixtureSkipTests {
    @Test("Imports 4 valid books, skips dict-key 'abc', clamps My Rate, normalizes Unseen, preserves File Type 3")
    func importsValidSkipsAnomalies() throws {
        guard let url = Bundle.module.url(forResource: "anomalies", withExtension: "plist", subdirectory: "Fixtures") else {
            Issue.record("anomalies.plist fixture missing")
            return
        }
        let outURL = URL(fileURLWithPath: "/tmp/anomalies-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: outURL) }

        var cmd = ImportCommand()
        cmd.xml = url.path
        cmd.out = outURL.path
        cmd.force = true
        cmd.quiet = true

        // ImportCommand throws ExitCode(1) when there are skipped books.
        do {
            try cmd.run()
            Issue.record("Expected ExitCode(1) due to skipped book")
        } catch let exit as ExitCode {
            #expect(exit == ExitCode(1))
        }

        // Verify SQLite content using sqlite3 shell.
        let bookCount = try runSQLite(db: outURL.path, sql: "SELECT COUNT(*) FROM book")
        #expect(bookCount == "4")

        // Verify File Type 3 was preserved (no anomaly skip for unknown enum values)
        let fileType3Count = try runSQLite(db: outURL.path, sql: "SELECT COUNT(*) FROM book WHERE file_type = 3")
        #expect(fileType3Count == "1")

        // Verify My Rate was clamped from 9 to 5
        let highRating = try runSQLite(db: outURL.path, sql: "SELECT rating FROM book WHERE id = 5")
        #expect(highRating == "5")

        // Verify Unseen was normalized: int 2 → 1 (true)
        let unseenForBook1 = try runSQLite(db: outURL.path, sql: "SELECT unseen FROM book WHERE id = 1")
        #expect(unseenForBook1 == "1")

        // G49: Path を持たない本は、表紙パスがアーカイブ本体を指していれば取り込み層が復元する
        // （以前は NULL のままで、本の在り処が失われていた）。
        let pathForBook2 = try runSQLite(db: outURL.path, sql: "SELECT IFNULL(path, 'NULL') FROM book WHERE id = 2")
        #expect(pathForBook2 == "/test/2.zip")

        // Verify dict-key 'abc' was skipped (not present in DB)
        let badKeyExists = try runSQLite(db: outURL.path, sql: "SELECT COUNT(*) FROM book WHERE id = 3")
        #expect(badKeyExists == "0")

        // skipped_count was 1 (just abc). After T26 with MalformedEntry added, it's 2.
        let skippedCount = try runSQLite(db: outURL.path, sql: "SELECT skipped_count FROM import_meta")
        #expect(skippedCount == "2")
    }

    private func runSQLite(db: String, sql: String) throws -> String {
        let proc = Process()
        proc.launchPath = "/usr/bin/sqlite3"
        proc.arguments = [db, sql]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
