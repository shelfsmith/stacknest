// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

@Suite("Migration v11 — cover_image_name column")
struct MigrationV11Tests {
    @Test
    func addsCoverImageNameAsNullableText() throws {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mig-v11-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let db = try DatabaseQueue(path: tmpURL.path)
        try db.write { dbConn in
            try Migration.apply(to: dbConn)
        }
        try db.read { dbConn in
            let info = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(book)")
            let cols = info.compactMap { ($0["name"] as? String) }
            #expect(cols.contains("cover_image_name"))
            let coverRow = info.first { ($0["name"] as? String) == "cover_image_name" }
            #expect((coverRow?["type"] as? String) == "TEXT")
            #expect(((coverRow?["notnull"] as? Int64).map(Int.init)) == 0)
        }
    }

    @Test
    func idempotentOnDoubleApply() throws {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mig-v11-idem-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let db = try DatabaseQueue(path: tmpURL.path)
        try db.write { try Migration.apply(to: $0) }
        try db.write { try Migration.apply(to: $0) }  // 二度目: エラーにならない
    }
}
