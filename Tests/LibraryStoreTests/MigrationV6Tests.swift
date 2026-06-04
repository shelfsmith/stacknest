// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

@Suite("Migration v6 - FTS5 with memo + filter indexes")
struct MigrationV6Tests {
    @Test func ftsHasMemoColumn() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let cols = try db.fetchFTSColumns()
        #expect(cols.contains("memo"))
        #expect(cols.contains("title"))
        #expect(cols.contains("author"))
        #expect(cols.contains("cover_name") == false)
    }

    @Test func filterIndexesExist() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let names = try db.fetchIndexNames()
        #expect(names.contains("idx_book_book_type"))
        #expect(names.contains("idx_book_unseen"))
        #expect(names.contains("idx_book_rating"))
        #expect(names.contains("idx_book_date_added"))
        #expect(names.contains("idx_book_play_date"))
    }

    @Test func memoIsSearchableViaFTS() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let baseBook = BookRow.testInstance(id: 1, title: "Generic")
        let bookWithMemo = BookRow(
            id: baseBook.id, title: baseBook.title, author: baseBook.author, genre: baseBook.genre,
            path: baseBook.path,
            dateAdded: baseBook.dateAdded, playDate: baseBook.playDate,
            bookType: baseBook.bookType, fileType: baseBook.fileType, pages: baseBook.pages,
            rating: baseBook.rating, unseen: baseBook.unseen,
            keywordA: baseBook.keywordA, keywordB: baseBook.keywordB, keywordC: baseBook.keywordC,
            neta: baseBook.neta, memo: "memorabilia"
        )
        try db.insertBook(bookWithMemo)
        let results = try db.searchBooks(query: "memorabilia", sidebarScope: .library)
        #expect(results.map(\.id) == [1])
    }

    @Test func migrationIsIdempotent() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.migrate()
        try db.migrate()
        let cols = try db.fetchFTSColumns()
        #expect(cols.contains("memo"))
        let names = try db.fetchIndexNames()
        #expect(names.filter { $0 == "idx_book_book_type" }.count == 1)
    }
}
