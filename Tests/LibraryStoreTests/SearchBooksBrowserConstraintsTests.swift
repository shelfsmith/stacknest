// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("searchBooks with browserConstraints")
struct SearchBooksBrowserConstraintsTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    private func makeBook(id: Int, genre: String?, author: String?, bookType: Int, rating: Int) -> BookRow {
        BookRow(
            id: id, title: "Book\(id)", author: author, genre: genre, path: nil,
            dateAdded: Date(),
            playDate: nil, bookType: bookType, fileType: 0, pages: nil,
            rating: rating, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: nil
        )
    }

    @Test func singleConstraintFilters() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "A", author: nil, bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 2, genre: "B", author: nil, bookType: 0, rating: 0))
        let result = try db.searchBooks(
            query: "",
            sidebarScope: .library,
            browserConstraints: [("genre", "A")]
        )
        #expect(Set(result.map(\.id)) == [1])
    }

    @Test func multipleConstraintsAreANDed() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "A", author: "X", bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 2, genre: "A", author: "Y", bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 3, genre: "B", author: "X", bookType: 0, rating: 0))
        let result = try db.searchBooks(
            query: "",
            sidebarScope: .library,
            browserConstraints: [("genre", "A"), ("author", "X")]
        )
        #expect(Set(result.map(\.id)) == [1])
    }

    @Test func integerConstraintBindsAsInt() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: nil, author: nil, bookType: 0, rating: 5))
        try db.insertBook(makeBook(id: 2, genre: nil, author: nil, bookType: 0, rating: 3))
        let result = try db.searchBooks(
            query: "",
            sidebarScope: .library,
            browserConstraints: [("rating", "5")]
        )
        #expect(Set(result.map(\.id)) == [1])
    }

    @Test func combinesWithFilterAndQuery() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "A", author: "山田", bookType: 0, rating: 5))
        try db.insertBook(makeBook(id: 2, genre: "A", author: "佐藤", bookType: 0, rating: 3))
        try db.insertBook(makeBook(id: 3, genre: "B", author: "山田", bookType: 0, rating: 5))
        var f = FilterState()
        f.ratingMin = 5
        let result = try db.searchBooks(
            query: "山田",
            sidebarScope: .library,
            filter: f,
            browserConstraints: [("genre", "A")]
        )
        // FTS 山田 (id 1, 3) ∩ rating>=5 (1, 3) ∩ genre=A (1, 2) = id 1
        #expect(Set(result.map(\.id)) == [1])
    }

    @Test func favoritesScopeWithBrowser() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "A", author: nil, bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 2, genre: "A", author: nil, bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 3, genre: "B", author: nil, bookType: 0, rating: 0))
        let favID = try db.ensureFavoritesShelf()
        try db.appendBooksToShelf(playlistID: favID, bookIDs: [1, 3])
        let result = try db.searchBooks(
            query: "",
            sidebarScope: .favorites(playlistID: favID),
            browserConstraints: [("genre", "A")]
        )
        // favorites {1, 3} ∩ genre=A {1, 2} = {1}
        #expect(Set(result.map(\.id)) == [1])
    }

    @Test func recentScopeWithBrowser() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "A", author: nil, bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 2, genre: "B", author: nil, bookType: 0, rating: 0))
        let result = try db.searchBooks(
            query: "",
            sidebarScope: .recent(days: 14),
            browserConstraints: [("genre", "A")]
        )
        #expect(Set(result.map(\.id)) == [1])
    }

    @Test func emptyConstraintsEqualsLegacyFetch() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "A", author: nil, bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 2, genre: "B", author: nil, bookType: 0, rating: 0))
        let withEmpty = try db.searchBooks(query: "", sidebarScope: .library, browserConstraints: [])
        let legacy = try db.searchBooks(query: "", sidebarScope: .library)
        #expect(Set(withEmpty.map(\.id)) == Set(legacy.map(\.id)))
    }
}
