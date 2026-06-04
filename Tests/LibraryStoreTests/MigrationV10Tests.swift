// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

@Suite("Migration v10 — series + volume columns")
struct MigrationV10Tests {
    @Test
    func addsSeriesAndVolumeColumnsAsNullable() throws {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mig-v10-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let db = try DatabaseQueue(path: tmpURL.path)
        try db.write { dbConn in
            try Migration.apply(to: dbConn)
        }
        try db.read { dbConn in
            let info = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(book)")
            let cols = info.compactMap { ($0["name"] as? String) }
            #expect(cols.contains("series"))
            #expect(cols.contains("volume"))
            let seriesRow = info.first { ($0["name"] as? String) == "series" }
            let volumeRow = info.first { ($0["name"] as? String) == "volume" }
            #expect((seriesRow?["type"] as? String) == "TEXT")
            #expect((volumeRow?["type"] as? String) == "REAL")
            // GRDB returns INTEGER columns as Int64; cast to Int for comparison
            #expect((seriesRow?["notnull"] as? Int64).map(Int.init) == 0)
            #expect((volumeRow?["notnull"] as? Int64).map(Int.init) == 0)
        }
    }

    @Test
    func idempotentOnDoubleApply() throws {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mig-v10-idempotent-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let db = try DatabaseQueue(path: tmpURL.path)
        // Apply twice — must not throw
        try db.write { dbConn in
            try Migration.apply(to: dbConn)
            try Migration.apply(to: dbConn)
        }
        try db.read { dbConn in
            let info = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(book)")
            let cols = info.compactMap { ($0["name"] as? String) }
            #expect(cols.contains("series"))
            #expect(cols.contains("volume"))
        }
    }
}
