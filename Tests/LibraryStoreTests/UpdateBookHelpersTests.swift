// SPDX-License-Identifier: MIT
import Testing
import Foundation
import StackroomFormat
@testable import LibraryStore

@Suite("Database update helpers")
struct UpdateBookHelpersTests {

    private func makeDBWithOneBook() throws -> (Database, Int) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upd_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: dbURL, mode: .createOrReplace)
        try db.migrate()
        let record = BookRecord(
            id: 0,
            title: "Foo",
            author: nil as String?,
            genre: nil as String?,
            path: "/old/Foo.zip",
            dateAdded: Date(),
            playDate: nil as Date?,
            bookType: 1,
            fileType: 2,
            pages: 0,
            myRate: 0,
            unseen: false
        )
        try db.insertBook(record)
        let id = try db.fetchAllBooks().first!.id
        return (db, id)
    }

    @Test
    func updateBookPathChangesPathOnly() throws {
        let (db, id) = try makeDBWithOneBook()
        try db.updateBookPath(id: id, newPath: "/new/Bar.zip")
        let row = try db.fetchAllBooks().first!
        #expect(row.path == "/new/Bar.zip")
        #expect(row.title == "Foo")
    }

    @Test
    func updateBookTitleChangesTitleOnly() throws {
        let (db, id) = try makeDBWithOneBook()
        try db.updateBookTitle(id: id, newTitle: "Renamed")
        let row = try db.fetchAllBooks().first!
        #expect(row.title == "Renamed")
        #expect(row.path == "/old/Foo.zip")
    }
}
