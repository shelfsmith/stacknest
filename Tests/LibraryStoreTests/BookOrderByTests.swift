// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// `bookOrderBy(path:scope:)`（`Database.swift:1313`）が返す ORDER BY を固定する。
///
/// **なぜ要るか**: G25b-2 で 18 の SQL ブロックを畳んだ際に ORDER BY をこの 1 関数へ集約したが、
/// 順序を検証するテストが 1 本も無かった。repo 内の複数行 `searchBooks` 表明はすべて `Set(...)` で、
/// 順序を見る 2 件は fast path 経由でこの関数に到達しない。
///
/// **現時点で実害は無い**（`limit` を渡す呼び出しはゼロなので ORDER BY は「どの行が返るか」を
/// 左右せず、消費側 2 つはどちらも Swift 側で並べ直す）。ただし Swift の `sorted(by:)` は
/// 安定性が保証されておらず、同値が多い列では SQL の順序が同値要素の並びとして表に出る。
///
/// **fast path に落ちないこと**が前提。空クエリ＋フィルタ空だと動的 SQL を通らない
/// （`Database.swift:1402`）ので、`nonEmptyFilter`（`ratingMin = 0`＝「未評価のみ」だが
/// このファイルの本はすべて rating=0 で作るので実際には何も除外しない）を必ず渡す。
struct BookOrderByTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    /// - Parameters:
    ///   - daysAgo: nil の場合は「現在時刻」（date_added の並びを作るのに使う）。
    private func book(id: Int, title: String, daysAgo: Double? = nil) -> BookRow {
        BookRow(
            id: id, title: title, author: nil, genre: nil, path: nil,
            dateAdded: daysAgo.map { Date(timeIntervalSinceNow: -$0 * 86_400) } ?? Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 0, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: nil
        )
    }

    /// fast path を避けるための「空でないが何も除外しない」フィルタ。
    /// `ratingMin = 0` は SQL 上は `b.rating = 0` になるが、`book()` は常に rating=0 で作るため
    /// このファイルの本は 1 冊も除外されない。
    private var nonEmptyFilter: FilterState {
        var f = FilterState(); f.ratingMin = 0; return f
    }

    @Test func shelfScopeOrdersByPlaylistPosition() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "A"))
        try db.insertBook(book(id: 2, title: "B"))
        try db.insertBook(book(id: 3, title: "C"))
        let shelf = try db.createUserShelf(title: "S")
        // position を id 順とは**逆**に入れる（id 順に落ちていたら気づけない）。
        try db.appendBooksToShelf(playlistID: shelf, bookIDs: [3, 1, 2])

        let rows = try db.searchBooks(query: "", sidebarScope: .shelf(playlistID: shelf),
                                       filter: nonEmptyFilter)
        #expect(rows.map(\.id) == [3, 1, 2])
    }

    @Test func recentScopeOrdersByDateAddedDescending() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "old", daysAgo: 3))
        try db.insertBook(book(id: 2, title: "mid", daysAgo: 2))
        try db.insertBook(book(id: 3, title: "new", daysAgo: 1))

        let rows = try db.searchBooks(query: "", sidebarScope: .recent(days: 100),
                                       filter: nonEmptyFilter)
        // date_added 降順（新しい順）。alphabetical(title) 順（mid, new, old）とは異なる並びにしてある。
        #expect(rows.map(\.id) == [3, 2, 1])
    }

    @Test func libraryScopeWithoutFTSOrdersByID() throws {
        let db = try setupDB()
        // どちらの title も "a" を含む（LIKE '%a%' に両方ヒットさせるため）が、
        // id 順と title 順で並びが逆になるよう選んである。
        try db.insertBook(book(id: 1, title: "zav"))  // id 順なら先、title 順なら後
        try db.insertBook(book(id: 2, title: "aav"))  // id 順なら後、title 順なら先

        // 1 文字クエリ = 非 FTS（LIKE fallback）経路。
        let rows = try db.searchBooks(query: "a", sidebarScope: .library, filter: nonEmptyFilter)
        #expect(rows.map(\.id) == [1, 2])
    }

    @Test func favoritesScopeOrdersByPlaylistPosition() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "A"))
        try db.insertBook(book(id: 2, title: "B"))
        let fav = try db.ensureFavoritesShelf()
        // position を id 順とは**逆**に入れる。
        try db.appendBooksToShelf(playlistID: fav, bookIDs: [2, 1])

        let rows = try db.searchBooks(query: "", sidebarScope: .favorites(playlistID: fav),
                                       filter: nonEmptyFilter)
        #expect(rows.map(\.id) == [2, 1])
    }
}
