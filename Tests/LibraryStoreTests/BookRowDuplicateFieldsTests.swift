// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("BookRow duplicate fields")
struct BookRowDuplicateFieldsTests {
    private func freshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brdup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        return db
    }

    /// Insert a book using the production insert path. Mirrors existing tests that
    /// build a BookRow directly (no `insertBookForTest` helper exists in this repo).
    private func insertBook(_ db: Database, id: Int, title: String, path: String?) throws {
        try db.insertBook(BookRow(
            id: id, title: title, author: nil, genre: nil, path: path,
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil
        ))
    }

    @Test func defaultsAreNil() throws {
        let db = try freshDB()
        try insertBook(db, id: 1, title: "A", path: "/tmp/a.zip")
        let book = try #require(try db.fetchAllBooks().first { $0.id == 1 })
        #expect(book.contentHash == nil)
        #expect(book.fileSize == nil)
        #expect(book.fileMtime == nil)
    }
}
