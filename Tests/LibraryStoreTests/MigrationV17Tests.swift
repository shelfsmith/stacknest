// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

/// v17: `book_viewer_state.spread_explicit` の追加＋backfill を、pre-v17 スキーマを直接組んで検証する。
/// backfill の要点: `updateLastPage`(progress writeback) の素の INSERT は列 DEFAULT
/// `spread_enabled=0 AND cover_offset=1` しか作れない。よって pre-v17 行のうちその形から外れるものは
/// 必ず `saveViewerState`(明示保存)由来 → 明示として復元し、ユーザーの見開き設定を昇格で失わない。
@Suite("Migration v17 — spread_explicit column + backfill")
struct MigrationV17Tests {
    /// pre-v17 の book_viewer_state（spread_explicit 列なし）を作る。
    private func createPreV17ViewerState(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE book_viewer_state (
                book_id        INTEGER PRIMARY KEY,
                spread_enabled INTEGER NOT NULL DEFAULT 0,
                cover_offset   INTEGER NOT NULL DEFAULT 1,
                last_page      INTEGER NOT NULL DEFAULT 0,
                updated_at     TEXT
            )
            """)
    }

    @Test("v17 ALTER adds the column and backfill restores explicit rows, keeps progress-only rows non-explicit")
    func altersAndBackfills() throws {
        let dq = try DatabaseQueue()
        try dq.write { db in
            try createPreV17ViewerState(db)
            // 明示 ON / 明示 OFF＋cover_offset=0 / progress-only(=DEFAULT 0,1)。
            try db.execute(sql: """
                INSERT INTO book_viewer_state (book_id, spread_enabled, cover_offset, last_page)
                VALUES (1, 1, 1, 0), (2, 0, 0, 0), (3, 0, 1, 5)
                """)
            // v17 migration が実行するのと同じ ALTER＋backfill。
            try db.execute(sql: Tables.migrateV17AddSpreadExplicit)
            try db.execute(sql: Tables.migrateV17BackfillSpreadExplicit)

            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(book_viewer_state)")
                .compactMap { $0["name"] as? String }
            #expect(cols.contains("spread_explicit"), "列が追加される")

            func explicit(_ id: Int) throws -> Int64? {
                try Int64.fetchOne(db, sql: "SELECT spread_explicit FROM book_viewer_state WHERE book_id = ?", arguments: [id])
            }
            #expect(try explicit(1) == 1, "明示 ON(spread_enabled=1) は DEFAULT では作れない＝明示由来として復元")
            #expect(try explicit(2) == 1, "明示 OFF＋cover_offset=0 は DEFAULT(1) から外れる＝明示由来として復元")
            #expect(try explicit(3) == 0, "progress-only(0/1=DEFAULT) は非明示のまま＝漏れ修正を維持")
            // 値そのものは backfill で変えない（spread_enabled/cover_offset/last_page は不変）。
            let spreadEnabled3 = try Int64.fetchOne(db, sql: "SELECT spread_enabled FROM book_viewer_state WHERE book_id = 3")
            #expect(spreadEnabled3 == 0)
        }
    }

    @Test("full Migration.apply reaches v17 with spread_explicit present and is idempotent")
    func fullMigrateAddsColumnIdempotently() throws {
        let dq = try DatabaseQueue()
        try dq.write { try Migration.apply(to: $0) }
        try dq.write { try Migration.apply(to: $0) }  // 二度目もエラーにならない
        try dq.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(book_viewer_state)")
                .compactMap { $0["name"] as? String }
            #expect(cols.contains("spread_explicit"))
        }
    }
}
