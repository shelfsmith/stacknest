// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Finder タグの前回同期値（G39）")
struct FinderTagBaselineTests {
    @Test func theColumnExistsAfterMigration() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let cols = try db.fetchTableColumnNames(tableName: "book")
        #expect(cols.contains("finder_tags_synced"))
    }

    @Test func baselineRoundTrips() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(BookRow.testInstance(id: 1, title: "Round Trip"))
        // 2 冊目は常に未同期のまま — bookID を無視して先頭行を返す/書くような
        // 取り違えバグが混じっていれば、この本の値がつられて動いて検出できる。
        try db.insertBook(BookRow.testInstance(id: 2, title: "Untouched"))

        // 未同期の初期状態は nil。
        #expect(try db.finderTagBaseline(bookID: 1) == nil)

        try db.setFinderTagBaseline(bookID: 1, value: "赤, 青")
        #expect(try db.finderTagBaseline(bookID: 1) == "赤, 青")
        #expect(try db.finderTagBaseline(bookID: 2) == nil)

        // 上書きも読み出せる。
        try db.setFinderTagBaseline(bookID: 1, value: "緑")
        #expect(try db.finderTagBaseline(bookID: 1) == "緑")

        // 「同期済みだが 0 件」は空文字列として区別して保持する（NULL には戻らない）。
        try db.setFinderTagBaseline(bookID: 1, value: "")
        #expect(try db.finderTagBaseline(bookID: 1) == "")

        // 明示的に nil へ戻せば「未同期」に戻る。
        try db.setFinderTagBaseline(bookID: 1, value: nil)
        #expect(try db.finderTagBaseline(bookID: 1) == nil)
        #expect(try db.finderTagBaseline(bookID: 2) == nil, "book 1 の操作が book 2 に漏れていない")
    }

    /// ★ 同期対象の項目を切り替えたら前回値は無効になる（spec §4.2）。
    /// 残したままだと、別項目の値を「前回のタグ」と誤認して**大量に削除**しかねない。
    @Test func switchingTheFieldClearsEveryBaseline() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(BookRow.testInstance(id: 1, title: "Book One"))
        try db.insertBook(BookRow.testInstance(id: 2, title: "Book Two"))

        try db.setFinderTagBaseline(bookID: 1, value: "赤, 青")
        try db.setFinderTagBaseline(bookID: 2, value: "")  // 同期済みだが 0 件、という状態も含めて確認

        #expect(try db.finderTagBaseline(bookID: 1) == "赤, 青")
        #expect(try db.finderTagBaseline(bookID: 2) == "")

        try db.clearAllFinderTagBaselines()

        #expect(try db.finderTagBaseline(bookID: 1) == nil)
        #expect(try db.finderTagBaseline(bookID: 2) == nil)
    }

    /// v19 の `ALTER TABLE ADD COLUMN` は冪等ガード（PRAGMA table_info チェック）付きであること。
    /// ガードを外すと 2 回目の `migrate()` で "duplicate column name" が飛ぶ。
    @Test func migrationIsIdempotent() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.migrate()
        try db.migrate()
        let cols = try db.fetchTableColumnNames(tableName: "book")
        #expect(cols.filter { $0 == "finder_tags_synced" }.count == 1)
    }

    @Test func theSyncFieldSettingDefaultsToUnset() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        #expect(try db.getLibrarySetting(key: "finderTagSyncField") == nil, "既定は同期しない")
    }
}
