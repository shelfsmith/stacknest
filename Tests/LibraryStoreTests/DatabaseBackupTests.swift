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

    @Test func quickCheckReturnsFalseOnCorruptDBWithoutThrowing() throws {
        // 破損ページに対し PRAGMA quick_check は SQLITE_CORRUPT を送出するが、
        // quickCheck() はそれを捕捉して false を返す（生エラーを伝播させない）。
        let dir = try tempDir()
        let url = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: url, mode: .createOrReplace)
        try db.migrate()
        // 本を 1 冊入れて 2 ページ目以降にデータを作る。
        for i in 0..<200 {
            try db.setLibrarySetting(key: "k\(i)", value: String(repeating: "x", count: 64))
        }
        db.close()
        // ヘッダ(先頭100B)は保ったまま、2 ページ目先頭の btree を破壊する。
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data(repeating: 0, count: 512))
        try handle.close()

        let reopened = try Database.openExisting(at: url)
        #expect(try reopened.quickCheck() == false)
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
