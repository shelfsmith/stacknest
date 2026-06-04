// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Bulk metadata updates")
struct BulkUpdateTests {
    private func setupWithBooks() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        for i in 1...5 {
            // Insert with unseen: true so setUnreadBulk can verify that
            // untouched books remain in their original state (true).
            let row = BookRow(
                id: i, title: "B\(i)", author: nil, genre: nil, path: nil,
                dateAdded: Date(),
                playDate: nil, bookType: 0, fileType: 0, pages: nil,
                rating: 0, unseen: true, keywordA: nil, keywordB: nil,
                keywordC: nil, neta: nil
            )
            try db.insertBook(row)
        }
        return db
    }

    @Test func setRatingSingle() throws {
        let db = try setupWithBooks()
        try db.setRating(bookID: 1, rating: 4)
        let book = try db.fetchBook(id: 1)
        #expect(book?.rating == 4)
    }

    @Test func setRatingBulk() throws {
        let db = try setupWithBooks()
        try db.setRating(bookIDs: [1, 3, 5], rating: 5)
        for id in [1, 3, 5] {
            #expect(try db.fetchBook(id: id)?.rating == 5)
        }
        for id in [2, 4] {
            #expect(try db.fetchBook(id: id)?.rating == 0)
        }
    }

    @Test func setUnreadSingle() throws {
        let db = try setupWithBooks()
        try db.setUnread(bookID: 1, unread: false)
        #expect(try db.fetchBook(id: 1)?.unseen == false)
    }

    @Test func setUnreadBulk() throws {
        let db = try setupWithBooks()
        try db.setUnread(bookIDs: [2, 4], unread: false)
        #expect(try db.fetchBook(id: 2)?.unseen == false)
        #expect(try db.fetchBook(id: 4)?.unseen == false)
        #expect(try db.fetchBook(id: 1)?.unseen == true)
    }

    @Test func setBookTypeSingle() throws {
        let db = try setupWithBooks()
        try db.setBookType(bookID: 1, type: 5)
        #expect(try db.fetchBook(id: 1)?.bookType == 5)
    }

    @Test func setBookTypeBulk() throws {
        let db = try setupWithBooks()
        try db.setBookType(bookIDs: [1, 2], type: 3)
        #expect(try db.fetchBook(id: 1)?.bookType == 3)
        #expect(try db.fetchBook(id: 2)?.bookType == 3)
    }

    @Test func setRatingClampsToValidRange() throws {
        let db = try setupWithBooks()
        try db.setRating(bookID: 1, rating: 99)  // out of range
        let r = try db.fetchBook(id: 1)?.rating ?? 0
        #expect(r >= 0 && r <= 5)
    }
}
