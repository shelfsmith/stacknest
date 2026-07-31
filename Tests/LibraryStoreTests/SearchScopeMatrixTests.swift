// SPDX-License-Identifier: MIT
//
// G25b-2 Task 1: 検索経路（空/1-2文字LIKE/3文字以上trigram）× scope（library/favorites/
// shelf/recent/smartShelf）の未検証マスを埋める安全網。Task 2 で `searchBooks` /
// `distinctValues` 内の同型 SQL ブロック（3経路 × 3分岐）を畳む前に、各組み合わせで
// scope の絞り込みが実際に効いていることをテストで固定する。
//
// 各テストは「結果が返ること」だけでなく「scope 外・query 不一致の本が除外されること」を
// 必ず主張する。そうしないと、畳んだ SQL が scope 条件や検索経路の条件を落としても
// テストが気付かない（詳細は task-1-brief.md）。
import Testing
import Foundation
import StackroomFormat
@testable import LibraryStore

@Suite("searchBooks / distinctValues: 検索経路 × scope の未検証マス")
struct SearchScopeMatrixTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    /// - Parameters:
    ///   - daysAgo: nil の場合は「現在時刻」（date_added フィルタの境界確認に使う）。
    private func book(
        id: Int, title: String, genre: String? = nil, author: String? = nil,
        daysAgo: Double? = nil
    ) -> BookRow {
        BookRow(
            id: id, title: title, author: author, genre: genre, path: nil,
            dateAdded: daysAgo.map { Date(timeIntervalSinceNow: -$0 * 86_400) } ?? Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 0, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: nil
        )
    }

    private func makeComicSmartShelf(_ db: Database, title: String = "コミック") throws -> Int64 {
        try db.createSmartShelf(title: title, conditions:
            SmartShelfConditions(match: .all, rules: [
                SmartShelfRule(id: UUID(), field: .genre, op: .contains, value: .text("コミック")),
            ]))
    }

    // MARK: - searchBooks: 4 マス

    // 1-2文字(LIKE) × recent
    @Test func searchBooksLikeFallbackRecentScopeFiltersByDateAndSubstring() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "CAB1", daysAgo: 2))   // LIKE 一致 ＋ 期間内 → hit
        try db.insertBook(book(id: 2, title: "CAB2", daysAgo: 40))  // LIKE 一致だが期間外 → miss
        try db.insertBook(book(id: 3, title: "XYZ", daysAgo: 2))    // 期間内だが LIKE 不一致 → miss
        let r = try db.searchBooks(query: "AB", sidebarScope: .recent(days: 14))
        #expect(r.map(\.id) == [1])
    }

    // 1-2文字(LIKE) × smartShelf
    @Test func searchBooksLikeFallbackSmartShelfScopeFiltersByConditionAndSubstring() throws {
        let db = try setupDB()
        let sid = try makeComicSmartShelf(db)
        try db.insertBook(book(id: 1, title: "CAB1", genre: "コミック"))   // LIKE 一致 ＋ 条件一致 → hit
        try db.insertBook(book(id: 2, title: "CAB2", genre: "小説"))      // LIKE 一致だが条件不一致 → miss
        try db.insertBook(book(id: 3, title: "XYZ", genre: "コミック"))    // 条件一致だが LIKE 不一致 → miss
        let r = try db.searchBooks(query: "AB", sidebarScope: .smartShelf(playlistID: sid))
        #expect(r.map(\.id) == [1])
    }

    // 3文字以上(trigram) × favorites
    @Test func searchBooksTrigramFavoritesScopeFiltersByMembershipAndSubstring() throws {
        let db = try setupDB()
        let favID = try db.ensureFavoritesShelf()
        try db.insertBook(book(id: 1, title: "ハイスコアガール"))  // trigram 一致 ＋ favorites → hit
        try db.insertBook(book(id: 2, title: "ハイスコアガール"))  // trigram 一致だが favorites 外 → miss
        try db.insertBook(book(id: 3, title: "別の本"))            // favorites だが trigram 不一致 → miss
        try db.appendBooksToShelf(playlistID: favID, bookIDs: [1, 3])
        let r = try db.searchBooks(query: "スコア", sidebarScope: .favorites(playlistID: favID))
        #expect(r.map(\.id) == [1])
    }

    // 3文字以上(trigram) × recent
    @Test func searchBooksTrigramRecentScopeFiltersByDateAndSubstring() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "ハイスコアガール", daysAgo: 2))    // trigram ＋ 期間内 → hit
        try db.insertBook(book(id: 2, title: "ハイスコアガール", daysAgo: 40))   // trigram だが期間外 → miss
        try db.insertBook(book(id: 3, title: "別の本", daysAgo: 2))              // 期間内だが trigram 不一致 → miss
        let r = try db.searchBooks(query: "スコア", sidebarScope: .recent(days: 14))
        #expect(r.map(\.id) == [1])
    }

    // MARK: - distinctValues: 10 マス
    //
    // task-1-brief.md の集計文言は「11 マスが空」だが、実測表（表の **0** セル数）は 10。
    // 表を正として、表に現れる **0** セルを全て埋める（task-1-report.md に記録）。

    // 空クエリ × shelf
    @Test func distinctValuesEmptyQueryShelfScopeFiltersByMembership() throws {
        let db = try setupDB()
        let sid = try db.createUserShelf(title: "S")
        try db.insertBook(book(id: 1, title: "B1", genre: "A"))   // shelf 内 → hit
        try db.insertBook(book(id: 2, title: "B2", genre: "B"))   // shelf 外 → miss
        try db.appendBooksToShelf(playlistID: sid, bookIDs: [1])
        let r = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .shelf(playlistID: sid))
        #expect(r == ["A"])
    }

    // 空クエリ × recent
    @Test func distinctValuesEmptyQueryRecentScopeFiltersByDate() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "B1", genre: "A", daysAgo: 2))    // 期間内 → hit
        try db.insertBook(book(id: 2, title: "B2", genre: "B", daysAgo: 40))   // 期間外 → miss
        let r = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .recent(days: 14))
        #expect(r == ["A"])
    }

    // 空クエリ × smartShelf
    @Test func distinctValuesEmptyQuerySmartShelfScopeFiltersByCondition() throws {
        let db = try setupDB()
        let sid = try makeComicSmartShelf(db)
        try db.insertBook(book(id: 1, title: "B1", genre: "コミック", author: "X"))   // 条件一致 → hit
        try db.insertBook(book(id: 2, title: "B2", genre: "小説", author: "Y"))       // 条件不一致 → miss
        let r = try db.distinctValues(forColumn: "author", query: "", sidebarScope: .smartShelf(playlistID: sid))
        #expect(r == ["X"])
    }

    // 1-2文字(LIKE) × shelf
    @Test func distinctValuesLikeFallbackShelfScopeFiltersByMembershipAndSubstring() throws {
        let db = try setupDB()
        let sid = try db.createUserShelf(title: "S")
        try db.insertBook(book(id: 1, title: "AB1", genre: "X"))   // LIKE 一致 ＋ shelf 内 → hit
        try db.insertBook(book(id: 2, title: "AB2", genre: "Y"))   // LIKE 一致だが shelf 外 → miss
        try db.insertBook(book(id: 3, title: "ZZ", genre: "Q"))    // shelf 内だが LIKE 不一致 → miss
        try db.appendBooksToShelf(playlistID: sid, bookIDs: [1, 3])
        let r = try db.distinctValues(forColumn: "genre", query: "AB", sidebarScope: .shelf(playlistID: sid))
        #expect(r == ["X"])
    }

    // 1-2文字(LIKE) × recent
    @Test func distinctValuesLikeFallbackRecentScopeFiltersByDateAndSubstring() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "AB1", genre: "X", daysAgo: 2))    // LIKE ＋ 期間内 → hit
        try db.insertBook(book(id: 2, title: "AB2", genre: "Y", daysAgo: 40))   // LIKE だが期間外 → miss
        try db.insertBook(book(id: 3, title: "ZZ", genre: "Q", daysAgo: 2))     // 期間内だが LIKE 不一致 → miss
        let r = try db.distinctValues(forColumn: "genre", query: "AB", sidebarScope: .recent(days: 14))
        #expect(r == ["X"])
    }

    // 1-2文字(LIKE) × smartShelf
    @Test func distinctValuesLikeFallbackSmartShelfScopeFiltersByConditionAndSubstring() throws {
        let db = try setupDB()
        let sid = try makeComicSmartShelf(db)
        try db.insertBook(book(id: 1, title: "AB1", genre: "コミック", author: "X"))  // LIKE ＋ 条件一致 → hit
        try db.insertBook(book(id: 2, title: "AB2", genre: "小説", author: "Y"))      // LIKE だが条件不一致 → miss
        try db.insertBook(book(id: 3, title: "ZZ", genre: "コミック", author: "Q"))    // 条件一致だが LIKE 不一致 → miss
        let r = try db.distinctValues(forColumn: "author", query: "AB", sidebarScope: .smartShelf(playlistID: sid))
        #expect(r == ["X"])
    }

    // 3文字以上(trigram) × favorites
    @Test func distinctValuesTrigramFavoritesScopeFiltersByMembershipAndSubstring() throws {
        let db = try setupDB()
        let favID = try db.ensureFavoritesShelf()
        try db.insertBook(book(id: 1, title: "ハイスコアガール", genre: "X"))  // trigram ＋ favorites → hit
        try db.insertBook(book(id: 2, title: "ハイスコアガール", genre: "Y"))  // trigram だが favorites 外 → miss
        try db.insertBook(book(id: 3, title: "別の本", genre: "Q"))            // favorites だが trigram 不一致 → miss
        try db.appendBooksToShelf(playlistID: favID, bookIDs: [1, 3])
        let r = try db.distinctValues(forColumn: "genre", query: "スコア", sidebarScope: .favorites(playlistID: favID))
        #expect(r == ["X"])
    }

    // 3文字以上(trigram) × shelf
    @Test func distinctValuesTrigramShelfScopeFiltersByMembershipAndSubstring() throws {
        let db = try setupDB()
        let sid = try db.createUserShelf(title: "S")
        try db.insertBook(book(id: 1, title: "ハイスコアガール", genre: "X"))  // trigram ＋ shelf 内 → hit
        try db.insertBook(book(id: 2, title: "ハイスコアガール", genre: "Y"))  // trigram だが shelf 外 → miss
        try db.insertBook(book(id: 3, title: "別の本", genre: "Q"))            // shelf 内だが trigram 不一致 → miss
        try db.appendBooksToShelf(playlistID: sid, bookIDs: [1, 3])
        let r = try db.distinctValues(forColumn: "genre", query: "スコア", sidebarScope: .shelf(playlistID: sid))
        #expect(r == ["X"])
    }

    // 3文字以上(trigram) × recent
    @Test func distinctValuesTrigramRecentScopeFiltersByDateAndSubstring() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "ハイスコアガール", genre: "X", daysAgo: 2))    // trigram ＋ 期間内 → hit
        try db.insertBook(book(id: 2, title: "ハイスコアガール", genre: "Y", daysAgo: 40))   // trigram だが期間外 → miss
        try db.insertBook(book(id: 3, title: "別の本", genre: "Q", daysAgo: 2))              // 期間内だが trigram 不一致 → miss
        let r = try db.distinctValues(forColumn: "genre", query: "スコア", sidebarScope: .recent(days: 14))
        #expect(r == ["X"])
    }

    // 3文字以上(trigram) × smartShelf
    @Test func distinctValuesTrigramSmartShelfScopeFiltersByConditionAndSubstring() throws {
        let db = try setupDB()
        let sid = try makeComicSmartShelf(db)
        try db.insertBook(book(id: 1, title: "ハイスコアガール", genre: "コミック", author: "X"))  // trigram ＋ 条件一致 → hit
        try db.insertBook(book(id: 2, title: "ハイスコアガール", genre: "小説", author: "Y"))      // trigram だが条件不一致 → miss
        try db.insertBook(book(id: 3, title: "別の本", genre: "コミック", author: "Q"))            // 条件一致だが trigram 不一致 → miss
        let r = try db.distinctValues(forColumn: "author", query: "スコア", sidebarScope: .smartShelf(playlistID: sid))
        #expect(r == ["X"])
    }
}
