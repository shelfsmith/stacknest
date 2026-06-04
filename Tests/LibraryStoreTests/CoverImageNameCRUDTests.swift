// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
import StackroomFormat

@Suite("cover_image_name CRUD")
struct CoverImageNameCRUDTests {
    private func makeDB() throws -> (Database, URL) {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cover-crud-\(UUID()).sqlite")
        let db = try Database.openFile(at: tmpURL, mode: .createOrReplace)
        try db.migrate()
        return (db, tmpURL)
    }

    @Test
    func insertAndFetchPreservesCoverImageName() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = BookRecord(id: 0, title: "T", coverImageName: "page05.jpg", dateAdded: Date())
        let id = try db.insertBookReturningID(rec)
        let fetched = try db.fetchAllBooks().first { $0.id == id }
        #expect(fetched?.coverImageName == "page05.jpg")
    }

    @Test
    func updateAppliesCoverImageNamePatch() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try db.insertBookReturningID(BookRecord(id: 0, title: "T", dateAdded: Date()))
        try db.updateBook(id: id, patch: BookPatch(coverImageName: "page03.jpg"))
        #expect(try db.fetchAllBooks().first?.coverImageName == "page03.jpg")
    }

    @Test
    func clearCoverImageNameSetsNull() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try db.insertBookReturningID(BookRecord(id: 0, title: "T", coverImageName: "page05.jpg", dateAdded: Date()))
        try db.updateBook(id: id, patch: BookPatch(clearCoverImageName: true))
        #expect(try db.fetchAllBooks().first?.coverImageName == nil)
    }

    @Test
    func nilCoverImageNameInPatchPreservesExisting() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try db.insertBookReturningID(BookRecord(id: 0, title: "T", coverImageName: "page05.jpg", dateAdded: Date()))
        try db.updateBook(id: id, patch: BookPatch(title: "U"))  // coverImageName 触らない
        #expect(try db.fetchAllBooks().first?.coverImageName == "page05.jpg")
    }
}
