// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

@Suite("Migration v5 - book.memo column")
struct MigrationV5Tests {
    @Test func freshDBHasMemoColumn() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let cols = try db.fetchBookColumnNames()
        #expect(cols.contains("memo"))
    }

    @Test func migrationIsIdempotent() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.migrate()
        try db.migrate()
        let cols = try db.fetchBookColumnNames()
        #expect(cols.filter { $0 == "memo" }.count == 1)
    }

    @Test func memoDefaultsToNullForNewBooks() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(BookRow.testInstance(id: 1, title: "B1"))
        let book = try db.fetchBook(id: 1)
        #expect(book?.memo == nil)
    }
}
