// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Database backup / integrity")
struct DatabaseBackupTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbackup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func quickCheckPassesOnHealthyDB() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        #expect(try db.quickCheck() == true)
    }

    @Test func integrityCheckReturnsOkOnHealthyDB() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        #expect(try db.integrityCheck() == ["ok"])
    }

    @Test func backupProducesOpenableCopyWithSameRows() throws {
        let dir = try tempDir()
        let srcURL = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: srcURL, mode: .createOrReplace)
        try db.migrate()
        try db.setLibrarySetting(key: "probe", value: "kept")

        let backupURL = dir.appendingPathComponent("backup.sqlite")
        try db.backup(to: backupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        let restored = try Database.openExisting(at: backupURL)
        #expect(try restored.getLibrarySetting(key: "probe") == "kept")
    }
}
