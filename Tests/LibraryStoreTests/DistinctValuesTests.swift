// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Database.distinctValues")
struct DistinctValuesTests {
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

    @Test func emptyLibraryReturnsEmpty() throws {
        let db = try setupDB()
        let values = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .library)
        #expect(values.isEmpty)
    }

    @Test func singleValueReturnsOne() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "コミック", author: nil, bookType: 0, rating: 0))
        let values = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .library)
        #expect(values == ["コミック"])
    }

    @Test func multipleValuesAscendingSort() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "小説", author: nil, bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 2, genre: "コミック", author: nil, bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 3, genre: "雑誌", author: nil, bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 4, genre: "コミック", author: nil, bookType: 0, rating: 0))
        let values = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .library)
        #expect(values.count == 3)
        #expect(values.contains("コミック"))
        #expect(values.contains("小説"))
        #expect(values.contains("雑誌"))
    }

    @Test func nullValuesExcluded() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "コミック", author: nil, bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 2, genre: nil, author: nil, bookType: 0, rating: 0))
        let values = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .library)
        #expect(values == ["コミック"])
    }

    @Test func integerColumnReturnsString() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: nil, author: nil, bookType: 0, rating: 5))
        try db.insertBook(makeBook(id: 2, genre: nil, author: nil, bookType: 0, rating: 3))
        let values = try db.distinctValues(forColumn: "rating", query: "", sidebarScope: .library)
        #expect(Set(values) == ["3", "5"])
    }

    @Test func filterAppliesToDistinct() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "コミック", author: nil, bookType: 0, rating: 5))
        try db.insertBook(makeBook(id: 2, genre: "小説", author: nil, bookType: 1, rating: 3))
        var f = FilterState()
        f.bookTypes = [0]
        let values = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .library, filter: f)
        #expect(values == ["コミック"])
    }

    @Test func searchQueryAppliesToDistinct() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "コミック", author: "山田", bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 2, genre: "小説", author: "佐藤", bookType: 0, rating: 0))
        let values = try db.distinctValues(forColumn: "genre", query: "山田", sidebarScope: .library)
        #expect(values == ["コミック"])
    }

    @Test func cascadingConstraintFilters() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "コミック", author: "山田", bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 2, genre: "コミック", author: "佐藤", bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 3, genre: "小説", author: "山田", bookType: 0, rating: 0))
        let values = try db.distinctValues(
            forColumn: "author",
            query: "",
            sidebarScope: .library,
            browserConstraints: [("genre", "コミック")]
        )
        #expect(Set(values) == ["山田", "佐藤"])
    }

    @Test func favoritesScopeAppliesToDistinct() throws {
        let db = try setupDB()
        try db.insertBook(makeBook(id: 1, genre: "A", author: nil, bookType: 0, rating: 0))
        try db.insertBook(makeBook(id: 2, genre: "B", author: nil, bookType: 0, rating: 0))
        let favID = try db.ensureFavoritesShelf()
        try db.appendBooksToShelf(playlistID: favID, bookIDs: [1])
        let values = try db.distinctValues(
            forColumn: "genre",
            query: "",
            sidebarScope: .favorites(playlistID: favID)
        )
        #expect(values == ["A"])
    }
}
