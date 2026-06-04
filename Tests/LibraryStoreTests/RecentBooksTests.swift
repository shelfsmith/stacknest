// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Recent books")
struct RecentBooksTests {
    /// Seed a book whose date_added is `daysAgo` days before now (real clock).
    private func makeBook(id: Int, daysAgo: Double) -> BookRow {
        BookRow(
            id: id, title: "B\(id)", author: nil, genre: nil,
            path: nil,
            dateAdded: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil,
            neta: nil
        )
    }

    @Test func emptyDBReturnsEmpty() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let recent = try db.fetchRecentBooks(days: 14)
        #expect(recent.isEmpty)
    }

    @Test func returnsOnlyBooksWithinDays() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        // 2d/10d within 14d window; 40d is outside.
        try db.insertBook(makeBook(id: 1, daysAgo: 2))
        try db.insertBook(makeBook(id: 2, daysAgo: 10))
        try db.insertBook(makeBook(id: 3, daysAgo: 40))
        let recent = try db.fetchRecentBooks(days: 14)
        // Ordered by date_added DESC → newest (2d) first.
        #expect(recent.map(\.id) == [1, 2])
    }

    @Test func boundaryBookJustInsideWindow() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        // 13d is inside a 14d window; 15d is outside.
        try db.insertBook(makeBook(id: 1, daysAgo: 13))
        try db.insertBook(makeBook(id: 2, daysAgo: 15))
        let recent = try db.fetchRecentBooks(days: 14)
        #expect(recent.map(\.id) == [1])
    }

    @Test func searchBooksRecentScopeWithinDaysOrderedDesc() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(makeBook(id: 1, daysAgo: 2))
        try db.insertBook(makeBook(id: 2, daysAgo: 10))
        try db.insertBook(makeBook(id: 3, daysAgo: 40))
        let results = try db.searchBooks(query: "", sidebarScope: .recent(days: 14))
        #expect(results.map(\.id) == [1, 2])
    }

    // MARK: - FX2: fetchRecentBookCount (COUNT-only, no row materialization)

    @Test func fetchRecentBookCountWithinDays() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        // 2d/10d within 14d window; 40d is outside → expect 2.
        try db.insertBook(makeBook(id: 1, daysAgo: 2))
        try db.insertBook(makeBook(id: 2, daysAgo: 10))
        try db.insertBook(makeBook(id: 3, daysAgo: 40))
        #expect(try db.fetchRecentBookCount(days: 14) == 2)
    }

    @Test func fetchRecentBookCountDays1Boundary() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        // Within a 1d window: 0.5d inside, 2d outside → expect 1.
        try db.insertBook(makeBook(id: 1, daysAgo: 0.5))
        try db.insertBook(makeBook(id: 2, daysAgo: 2))
        #expect(try db.fetchRecentBookCount(days: 1) == 1)
    }

    @Test func fetchRecentBookCountEmptyDB() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        #expect(try db.fetchRecentBookCount(days: 14) == 0)
    }
}
