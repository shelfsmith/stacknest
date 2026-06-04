// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
@testable import StackroomFormat

@Suite("Database addToBookField / clearBookField")
struct AddToBookFieldTests {
    private func makeDBWithOneBook(genre: String?) throws -> (Database, Int) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("addfield_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        let rec = BookRecord(
            id: 0, title: "T", author: nil, genre: genre,
            path: "/x.zip", dateAdded: Date(), playDate: nil,
            bookType: 0, fileType: 2, pages: 0, myRate: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil
        )
        let id = try db.insertBookReturningID(rec)
        return (db, id)
    }

    @Test
    func appendToEmpty() throws {
        let (db, id) = try makeDBWithOneBook(genre: nil)
        let added = try db.addToBookField(id: id, column: "genre", value: "マンガ")
        #expect(added == true)
        let row = try db.fetchAllBooks().first!
        #expect(row.genre == "マンガ")
    }

    @Test
    func appendToExisting() throws {
        let (db, id) = try makeDBWithOneBook(genre: "マンガ")
        let added = try db.addToBookField(id: id, column: "genre", value: "小説")
        #expect(added == true)
        let row = try db.fetchAllBooks().first!
        #expect(row.genre == "マンガ, 小説")
    }

    @Test
    func appendDuplicateReturnsFalse() throws {
        let (db, id) = try makeDBWithOneBook(genre: "マンガ, 小説")
        let added = try db.addToBookField(id: id, column: "genre", value: "マンガ")
        #expect(added == false)
        let row = try db.fetchAllBooks().first!
        #expect(row.genre == "マンガ, 小説")
    }

    @Test
    func clearSetsNull() throws {
        let (db, id) = try makeDBWithOneBook(genre: "マンガ, 小説")
        try db.clearBookField(id: id, column: "genre")
        let row = try db.fetchAllBooks().first!
        #expect(row.genre == nil)
    }

    @Test
    func addToInvalidColumnThrows() throws {
        let (db, id) = try makeDBWithOneBook(genre: nil)
        #expect(throws: Error.self) {
            _ = try db.addToBookField(id: id, column: "title", value: "X")  // title はマルチ値対象外
        }
    }

    @Test
    func clearInvalidColumnThrows() throws {
        let (db, id) = try makeDBWithOneBook(genre: nil)
        #expect(throws: Error.self) {
            try db.clearBookField(id: id, column: "title")
        }
    }
}
