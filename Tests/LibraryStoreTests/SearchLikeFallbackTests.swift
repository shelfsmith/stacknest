// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("LIKE fallback for 1-2 char query")
struct SearchLikeFallbackTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    private func makeBook(id: Int, title: String, author: String? = nil) -> BookRow {
        BookRow(
            id: id, title: title, author: author, genre: nil, path: nil,
            dateAdded: Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 0, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: nil
        )
    }

    @Test func twoCharQueryHitsViaLike() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "DASH"))
        try db.insertBook(makeBook(id: 2, title: "Foo"))
        let r = try db.searchBooks(query: "DA", sidebarScope: .library)
        #expect(Set(r.map(\.id)) == [1])
    }

    @Test func oneCharQueryHitsViaLike() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "あいうえお"))
        try db.insertBook(makeBook(id: 2, title: "Foo"))
        let r = try db.searchBooks(query: "あ", sidebarScope: .library)
        #expect(r.map(\.id) == [1])
    }

    @Test func likePatternMetacharsAreEscaped() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "100%"))
        try db.insertBook(makeBook(id: 2, title: "100A"))
        let r = try db.searchBooks(query: "0%", sidebarScope: .library)
        #expect(r.map(\.id) == [1])
    }

    @Test func likeMatchesAcrossMultipleColumns() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "AB", author: nil))
        try db.insertBook(makeBook(id: 2, title: "Foo", author: "AB"))
        let r = try db.searchBooks(query: "AB", sidebarScope: .library)
        #expect(Set(r.map(\.id)) == [1, 2])
    }

    @Test func likeFallbackPlusFilter() throws {
        let db = try setupDB()
        try db.insertBook(BookRow(
            id: 1, title: "AB", author: nil, genre: nil, path: nil,
            dateAdded: Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 5, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: nil
        ))
        try db.insertBook(BookRow(
            id: 2, title: "ABC", author: nil, genre: nil, path: nil,
            dateAdded: Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 1, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: nil
        ))
        var f = FilterState()
        f.ratingMin = 5
        let r = try db.searchBooks(query: "AB", sidebarScope: .library, filter: f)
        #expect(r.map(\.id) == [1])
    }

    @Test func likeFallbackInFavoritesScope() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "AB"))
        try db.insertBook(makeBook(id: 2, title: "AB"))
        let favID = try db.ensureFavoritesShelf()
        try db.appendBooksToShelf(playlistID: favID, bookIDs: [1])
        let r = try db.searchBooks(query: "AB", sidebarScope: .favorites(playlistID: favID))
        #expect(r.map(\.id) == [1])
    }

    @Test func emptyQueryStillUsesEmptyPath() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "Foo"))
        try db.insertBook(makeBook(id: 2, title: "Bar"))
        let r = try db.searchBooks(query: "", sidebarScope: .library)
        #expect(Set(r.map(\.id)) == [1, 2])
    }
}
