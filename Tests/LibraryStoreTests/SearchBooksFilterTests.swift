// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("searchBooks with FilterState")
struct SearchBooksFilterTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    private func insertSampleBooks(_ db: Database) throws {
        let now = Date()
        let week = TimeInterval(7 * 86_400)
        try db.insertBook(makeBook(id: 1, title: "Thick A", bookType: 0, rating: 5, unseen: false, dateAdded: now, playDate: now))
        try db.insertBook(makeBook(id: 2, title: "Thick B", bookType: 0, rating: 0, unseen: true, dateAdded: now.addingTimeInterval(-week), playDate: nil))
        try db.insertBook(makeBook(id: 3, title: "Thin A", bookType: 1, rating: 3, unseen: false, dateAdded: now.addingTimeInterval(-week * 5), playDate: now.addingTimeInterval(-week * 3)))
        try db.insertBook(makeBook(id: 4, title: "Movie A", bookType: 5, rating: 1, unseen: true, dateAdded: now.addingTimeInterval(-week * 10), playDate: nil))
    }

    private func makeBook(id: Int, title: String, bookType: Int, rating: Int, unseen: Bool, dateAdded: Date, playDate: Date?) -> BookRow {
        BookRow(
            id: id, title: title, author: nil, genre: nil, path: nil,
            dateAdded: dateAdded,
            playDate: playDate, bookType: bookType, fileType: 0, pages: nil,
            rating: rating, unseen: unseen, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: nil
        )
    }

    // MARK: - bookTypes

    @Test func filterByBookTypeSingle() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        var f = FilterState()
        f.bookTypes = [1]
        let results = try db.searchBooks(query: "", sidebarScope: .library, filter: f)
        #expect(Set(results.map(\.id)) == [3])
    }

    @Test func filterByBookTypeMultiple() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        var f = FilterState()
        f.bookTypes = [0, 5]
        let results = try db.searchBooks(query: "", sidebarScope: .library, filter: f)
        #expect(Set(results.map(\.id)) == [1, 2, 4])
    }

    @Test func emptyBookTypesMeansAll() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        let f = FilterState()
        let results = try db.searchBooks(query: "", sidebarScope: .library, filter: f)
        #expect(Set(results.map(\.id)) == [1, 2, 3, 4])
    }

    // MARK: - unseen

    @Test func filterByUnreadOnly() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        var f = FilterState()
        f.unseen = .unreadOnly
        let results = try db.searchBooks(query: "", sidebarScope: .library, filter: f)
        #expect(Set(results.map(\.id)) == [2, 4])
    }

    @Test func filterByReadOnly() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        var f = FilterState()
        f.unseen = .readOnly
        let results = try db.searchBooks(query: "", sidebarScope: .library, filter: f)
        #expect(Set(results.map(\.id)) == [1, 3])
    }

    // MARK: - rating

    @Test func filterByRatingMinPositive() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        var f = FilterState()
        f.ratingMin = 3
        let results = try db.searchBooks(query: "", sidebarScope: .library, filter: f)
        #expect(Set(results.map(\.id)) == [1, 3])
    }

    @Test func filterByRatingMinZeroOnlyMatchesRatingZero() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        var f = FilterState()
        f.ratingMin = 0
        let results = try db.searchBooks(query: "", sidebarScope: .library, filter: f)
        #expect(Set(results.map(\.id)) == [2])
    }

    // MARK: - date

    @Test func filterByDateAddedWithin8Days() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        var f = FilterState()
        f.dateAdded = .init(direction: .within, days: 8)
        let results = try db.searchBooks(query: "", sidebarScope: .library, filter: f)
        #expect(Set(results.map(\.id)) == [1, 2])
    }

    @Test func filterByPlayDateOlderThan20DaysExcludesNull() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        var f = FilterState()
        f.playDate = .init(direction: .olderThan, days: 20)
        let results = try db.searchBooks(query: "", sidebarScope: .library, filter: f)
        #expect(Set(results.map(\.id)) == [3])
    }

    // MARK: - combined

    @Test func filterByBookTypeAndUnseen() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        var f = FilterState()
        f.bookTypes = [0]
        f.unseen = .unreadOnly
        let results = try db.searchBooks(query: "", sidebarScope: .library, filter: f)
        #expect(Set(results.map(\.id)) == [2])
    }

    @Test func emptyFilterEqualsLegacyFetch() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        let allWithEmpty = try db.searchBooks(query: "", sidebarScope: .library, filter: FilterState())
        let allDefault = try db.searchBooks(query: "", sidebarScope: .library)
        #expect(Set(allWithEmpty.map(\.id)) == Set(allDefault.map(\.id)))
    }

    // MARK: - favorites/shelf scope

    @Test func filterAppliesInsideFavorites() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        let favID = try db.ensureFavoritesShelf()
        try db.appendBooksToShelf(playlistID: favID, bookIDs: [1, 2, 3])
        var f = FilterState()
        f.unseen = .unreadOnly
        let results = try db.searchBooks(query: "", sidebarScope: .favorites(playlistID: favID), filter: f)
        #expect(Set(results.map(\.id)) == [2])
    }

    @Test func filterAppliesInsideShelf() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        let pid = try db.createUserShelf(title: "ShelfTest")
        try db.appendBooksToShelf(playlistID: pid, bookIDs: [2, 3, 4])
        var f = FilterState()
        f.bookTypes = [1, 5]
        let results = try db.searchBooks(query: "", sidebarScope: .shelf(playlistID: pid), filter: f)
        #expect(Set(results.map(\.id)) == [3, 4])
    }

    // MARK: - recent scope

    @Test func filterAppliesToRecent() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        var f = FilterState()
        f.ratingMin = 3
        // recent(days:14): only id1 (now) and id2 (now-7d) are within window;
        // id3 (now-35d) and id4 (now-70d) are excluded. ratingMin:3 then keeps
        // id1 (rating 5) and drops id2 (rating 0) → {1}.
        let results = try db.searchBooks(query: "", sidebarScope: .recent(days: 14), filter: f)
        #expect(Set(results.map(\.id)) == [1])
    }

    // MARK: - FTS combined with filter

    @Test func filterAppliesWithFTSQueryInLibrary() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        var f = FilterState()
        f.unseen = .unreadOnly
        let results = try db.searchBooks(query: "Thick", sidebarScope: .library, filter: f)
        #expect(Set(results.map(\.id)) == [2])
    }

    @Test func filterAppliesWithFTSQueryInShelf() throws {
        let db = try setupDB()
        try insertSampleBooks(db)
        let pid = try db.createUserShelf(title: "ShelfTest")
        try db.appendBooksToShelf(playlistID: pid, bookIDs: [1, 2, 3])
        var f = FilterState()
        f.bookTypes = [0]
        let results = try db.searchBooks(query: "Thick", sidebarScope: .shelf(playlistID: pid), filter: f)
        #expect(Set(results.map(\.id)) == [1, 2])
    }
}
