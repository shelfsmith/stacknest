// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackroomImportCLI

@Suite("Full fixture E2E")
struct FullFixtureE2ETests {
    @Test("Imports 10 books and 3 playlists with all fields, writes import_meta")
    func importsFullFixture() throws {
        guard let url = Bundle.module.url(forResource: "full", withExtension: "plist", subdirectory: "Fixtures") else {
            Issue.record("full.plist fixture missing")
            return
        }
        let outURL = URL(fileURLWithPath: "/tmp/full-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: outURL) }

        var cmd = ImportCommand()
        cmd.xml = url.path
        cmd.out = outURL.path
        cmd.force = true
        cmd.quiet = true
        try cmd.run()

        // Verify via sqlite3 shell (Database.openFile in createOrFail mode would fail because file exists).
        let bookCount = try Self.runSQLite(db: outURL.path, sql: "SELECT COUNT(*) FROM book")
        #expect(bookCount == "10")

        let playlistCount = try Self.runSQLite(db: outURL.path, sql: "SELECT COUNT(*) FROM playlist")
        #expect(playlistCount == "3")

        let playlistItemCount = try Self.runSQLite(db: outURL.path, sql: "SELECT COUNT(*) FROM playlist_item")
        // Playlist 1 has 3 items, Playlist 2 has 3 items, Playlist 3 has 0 items → 6 total
        #expect(playlistItemCount == "6")

        let importMetaCount = try Self.runSQLite(db: outURL.path, sql: "SELECT COUNT(*) FROM import_meta")
        #expect(importMetaCount == "1")
    }

    /// Runs `sqlite3` shell command for verification (alternative to opening the DB
    /// in another Database instance, which would conflict with the createOrFail rule).
    static func runSQLite(db: String, sql: String) throws -> String {
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
