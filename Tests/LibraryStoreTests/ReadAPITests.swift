// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
import StackroomFormat

@Suite("Database read API")
struct ReadAPITests {
    private func makeBook(id: Int, title: String) -> BookRecord {
        BookRecord(
            id: id,
            title: title,
            genre: "g",
            coverImagePath: "/c",
            dateAdded: Date(timeIntervalSince1970: TimeInterval(id) * 1000),
            bookType: 0, fileType: 2,
            myRate: 0, unseen: false
        )
    }

    @Test("fetchAllBooks returns all rows ordered by date_added DESC")
    func fetchAllBooksOrdersByDateDesc() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(makeBook(id: 1, title: "Old"))
        try db.insertBook(makeBook(id: 2, title: "New"))
        try db.insertBook(makeBook(id: 3, title: "Newest"))

        let rows = try db.fetchAllBooks()
        #expect(rows.count == 3)
        #expect(rows.map(\.title) == ["Newest", "New", "Old"])
    }

    @Test("fetchBook(id:) returns nil for missing id")
    func fetchBookReturnsNilForMissing() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let row = try db.fetchBook(id: 999)
        #expect(row == nil)
    }

    @Test("fetchBook(id:) returns row for present id")
    func fetchBookReturnsPresentRow() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(makeBook(id: 42, title: "Hello"))
        let row = try db.fetchBook(id: 42)
        #expect(row?.title == "Hello")
        #expect(row?.id == 42)
    }

}
