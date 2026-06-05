// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Migration v15 — content_hash/file_size/file_mtime")
struct MigrationV15Tests {
    private func openMigratedDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mig15_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test func addsThreeColumns() throws {
        let db = try openMigratedDB()
        let cols = try db.fetchBookColumnNames()
        #expect(cols.contains("content_hash"))
        #expect(cols.contains("file_size"))
        #expect(cols.contains("file_mtime"))
    }

    @Test func migrationIsIdempotent() throws {
        let db = try openMigratedDB()
        try db.migrate()   // 2 回目も安全
        let cols = try db.fetchBookColumnNames()
        #expect(cols.filter { $0 == "content_hash" }.count == 1)
    }
}
