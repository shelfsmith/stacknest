// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

@Suite("Migration v4 - FTS5 + library_settings")
struct MigrationV4Tests {
    @Test func freshDBHasFTS5Table() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let exists = try db.fetchTableNames().contains("book_fts")
        #expect(exists)
    }

    @Test func freshDBHasLibrarySettingsTable() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let exists = try db.fetchTableNames().contains("library_settings")
        #expect(exists)
    }

    @Test func migrationIsIdempotent() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.migrate()
        try db.migrate()
        let names = try db.fetchTableNames()
        #expect(names.filter { $0 == "book_fts" }.count == 1)
        #expect(names.filter { $0 == "library_settings" }.count == 1)
    }

    @Test func insertingBookPopulatesFTS() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(BookRow.testInstance(id: 1, title: "朝食会"))
        let cnt = try db.fetchFTSCount()
        #expect(cnt == 1)
    }

    @Test func deletingBookRemovesFromFTS() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(BookRow.testInstance(id: 1, title: "朝食会"))
        try db.deleteBook(id: 1)
        let cnt = try db.fetchFTSCount()
        #expect(cnt == 0)
    }
}
