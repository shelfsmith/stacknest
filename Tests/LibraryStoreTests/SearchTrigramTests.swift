// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Trigram FTS substring search")
struct SearchTrigramTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    private func makeBook(id: Int, title: String) -> BookRow {
        BookRow(
            id: id, title: title, author: nil, genre: nil, path: nil,
            dateAdded: Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 0, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: nil
        )
    }

    @Test func substringInMiddleOfTitleHits() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "ハイスコアガール DASH 第08巻"))
        #expect(try db.searchBooks(query: "スコア", sidebarScope: .library).map(\.id) == [1])
        #expect(try db.searchBooks(query: "ガール", sidebarScope: .library).map(\.id) == [1])
        #expect(try db.searchBooks(query: "ASH", sidebarScope: .library).map(\.id) == [1])
        #expect(try db.searchBooks(query: "08巻", sidebarScope: .library).map(\.id) == [1])
    }

    @Test func prefixMatchStillHits() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "ハイスコアガール DASH 第08巻"))
        #expect(try db.searchBooks(query: "ハイスコア", sidebarScope: .library).map(\.id) == [1])
        #expect(try db.searchBooks(query: "DASH", sidebarScope: .library).map(\.id) == [1])
    }

    @Test func noDuplicateRowsForMultiColumnHit() throws {
        let db = try setupDB()
        let book = BookRow(
            id: 1, title: "テスト", author: "テスト", genre: "テスト",
            path: nil, dateAdded: Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 0, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: nil
        )
        try db.insertBook(book)
        let r = try db.searchBooks(query: "テスト", sidebarScope: .library)
        #expect(r.count == 1)
    }

    @Test func quoteCharacterIsEscaped() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: #"Title with "quote" inside"#))
        let r = try db.searchBooks(query: #""quote""#, sidebarScope: .library)
        #expect(r.map(\.id) == [1])
    }

    @Test func searchByMemoColumn() throws {
        let db = try setupDB()
        let book = BookRow(
            id: 1, title: "Title", author: nil, genre: nil, path: nil,
            dateAdded: Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 0, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: "memorabilia content"
        )
        try db.insertBook(book)
        #expect(try db.searchBooks(query: "memora", sidebarScope: .library).map(\.id) == [1])
    }
}
