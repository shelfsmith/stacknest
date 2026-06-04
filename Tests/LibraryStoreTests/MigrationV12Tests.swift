// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

@Suite("Migration v12 — cover_crop_rect column")
struct MigrationV12Tests {
    @Test
    func addsCoverCropRectAsNullableText() throws {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mig-v12-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let db = try DatabaseQueue(path: tmpURL.path)
        try db.write { dbConn in
            try Migration.apply(to: dbConn)
        }
        try db.read { dbConn in
            let info = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(book)")
            let cols = info.compactMap { ($0["name"] as? String) }
            #expect(cols.contains("cover_crop_rect"))
            let row = info.first { ($0["name"] as? String) == "cover_crop_rect" }
            #expect((row?["type"] as? String) == "TEXT")
            #expect(((row?["notnull"] as? Int64).map(Int.init)) == 0)
        }
    }

    @Test
    func idempotentOnDoubleApply() throws {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mig-v12-idem-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let db = try DatabaseQueue(path: tmpURL.path)
        try db.write { try Migration.apply(to: $0) }
        try db.write { try Migration.apply(to: $0) }
    }
}
