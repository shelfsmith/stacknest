// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Database.distinctValues query branching (trigram + LIKE)")
struct DistinctValuesTrigramTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    private func makeBook(id: Int, title: String, genre: String?, author: String?) -> BookRow {
        BookRow(
            id: id, title: title, author: author, genre: genre, path: nil,
            dateAdded: Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 0, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: nil
        )
    }

    @Test func threeCharSubstringFiltersDistinct() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "ハイスコアガール", genre: "コミック", author: nil))
        try db.insertBook(makeBook(id: 2, title: "Foo", genre: "小説", author: nil))
        let r = try db.distinctValues(forColumn: "genre", query: "スコア", sidebarScope: .library)
        #expect(r == ["コミック"])
    }

    @Test func twoCharQueryUsesLikeFallback() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "DASH", genre: "コミック", author: nil))
        try db.insertBook(makeBook(id: 2, title: "Foo", genre: "小説", author: nil))
        let r = try db.distinctValues(forColumn: "genre", query: "DA", sidebarScope: .library)
        #expect(r == ["コミック"])
    }

    @Test func emptyQueryUnchanged() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "Foo", genre: "コミック", author: nil))
        try db.insertBook(makeBook(id: 2, title: "Bar", genre: "小説", author: nil))
        let r = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .library)
        #expect(Set(r) == ["コミック", "小説"])
    }

    @Test func likeFallbackInFavoritesScope() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "AB", genre: "X", author: nil))
        try db.insertBook(makeBook(id: 2, title: "Foo", genre: "Y", author: nil))
        let favID = try db.ensureFavoritesShelf()
        try db.appendBooksToShelf(playlistID: favID, bookIDs: [1, 2])
        let r = try db.distinctValues(
            forColumn: "genre",
            query: "AB",
            sidebarScope: .favorites(playlistID: favID)
        )
        #expect(r == ["X"])
    }

    @Test func likeFallbackPlusBrowserConstraints() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, title: "AB", genre: "X", author: "John"))
        try db.insertBook(makeBook(id: 2, title: "AB", genre: "Y", author: "Jane"))
        let r = try db.distinctValues(
            forColumn: "genre",
            query: "AB",
            sidebarScope: .library,
            browserConstraints: [("author", "John")]
        )
        #expect(r == ["X"])
    }
}
