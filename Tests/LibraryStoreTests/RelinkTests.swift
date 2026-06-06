// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Relink tests")
struct RelinkTests {

    private func freshDB() throws -> Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relink_\(UUID().uuidString).sqlite")
        let db = try Database.openFile(at: url, mode: .createOrReplace)
        try db.migrate()
        return db
    }

    /// Insert a book using the internal BookRow path (same pattern as BookRowDuplicateFieldsTests).
    private func insertBook(_ db: Database, id: Int, path: String) throws {
        try db.insertBook(BookRow(
            id: id, title: "Book \(id)", author: nil, genre: nil, path: path,
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil
        ))
    }

    /// relinkBook: path が更新され、contentHash/fileSize/fileMtime が nil になること。
    @Test func relinkUpdatesPathAndClearsHash() throws {
        let db = try freshDB()
        try insertBook(db, id: 1, path: "/old/a.zip")
        // Set a hash first so we can verify it's cleared.
        try db.updateBookContentHash(id: 1, hash: "deadbeef", size: 12345, mtime: 1_000_000)

        // Pre-condition: hash is set.
        let before = try #require(try db.fetchBook(id: 1))
        #expect(before.contentHash == "deadbeef")
        #expect(before.fileSize == 12345)

        // Act.
        try db.relinkBook(id: 1, newPath: "/new/a.zip")

        // Assert: path updated, hash cleared.
        let after = try #require(try db.fetchBook(id: 1))
        #expect(after.path == "/new/a.zip")
        #expect(after.contentHash == nil)
        #expect(after.fileSize == nil)
        #expect(after.fileMtime == nil)
    }

    /// applyRelinks: 複数本を 1 トランザクションで再リンクできること。
    @Test func applyRelinksBatch() throws {
        let db = try freshDB()
        try insertBook(db, id: 1, path: "/old/1.zip")
        try insertBook(db, id: 2, path: "/old/2.zip")

        try db.applyRelinks([
            (id: 1, newPath: "/new/1.zip"),
            (id: 2, newPath: "/new/2.zip"),
        ])

        let book1 = try #require(try db.fetchBook(id: 1))
        let book2 = try #require(try db.fetchBook(id: 2))
        #expect(book1.path == "/new/1.zip")
        #expect(book2.path == "/new/2.zip")
    }
}
