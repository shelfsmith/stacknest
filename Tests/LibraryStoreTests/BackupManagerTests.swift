// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("BackupManager")
struct BackupManagerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bmgr_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func changeCounterIncrementsAfterWrite() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: url, mode: .createOrReplace)
        try db.migrate()
        db.close()
        let before = BackupManager.changeCounter(of: url)
        #expect(before != nil)

        let db2 = try Database.openExisting(at: url)
        try db2.setLibrarySetting(key: "x", value: "1")
        db2.close()
        let after = BackupManager.changeCounter(of: url)
        #expect(after != nil)
        #expect(after != before)
    }

    @Test func changeCounterNilForMissingFile() throws {
        let dir = try tempDir()
        #expect(BackupManager.changeCounter(of: dir.appendingPathComponent("nope.sqlite")) == nil)
    }
}
