// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
@testable import StackroomFormat

@Suite("applyStampToBooks — 一括スタンプ append/clear")
struct StampApplyTests {
    private func makeDBWithBook(genre: String? = nil, keywordA: String? = nil) throws -> (Database, Int) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stampapply_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        let rec = BookRecord(
            id: 0, title: "T", author: nil, genre: genre,
            path: "/x.zip", dateAdded: Date(), playDate: nil,
            bookType: 0, fileType: 2, pages: 0, myRate: 0, unseen: false,
            keywordA: keywordA, keywordB: nil, keywordC: nil, neta: nil
        )
        let id = try db.insertBookReturningID(rec)
        return (db, id)
    }

    @Test func appendAddsToExistingMultiValue() throws {
        let (db, id) = try makeDBWithBook(genre: "少年")
        let n = try applyStampToBooks(db: db, field: "genre", value: "SF", clear: false, bookIDs: [id])
        #expect(n == 1)
        let row = try #require(try db.fetchBook(id: id))
        #expect(row.genre == "少年, SF")
    }

    @Test func appendToNilStarts() throws {
        let (db, id) = try makeDBWithBook(keywordA: nil)
        _ = try applyStampToBooks(db: db, field: "keyword_a", value: "完結", clear: false, bookIDs: [id])
        let row = try #require(try db.fetchBook(id: id))
        #expect(row.keywordA == "完結")
    }

    @Test func clearSetsNull() throws {
        let (db, id) = try makeDBWithBook(genre: "少年, SF")
        _ = try applyStampToBooks(db: db, field: "genre", value: nil, clear: true, bookIDs: [id])
        let row = try #require(try db.fetchBook(id: id))
        #expect(row.genre == nil)
    }

    @Test func invalidFieldThrows() throws {
        let (db, _) = try makeDBWithBook()
        #expect(throws: StampApplyError.self) {
            try applyStampToBooks(db: db, field: "title", value: "x", clear: false, bookIDs: [])
        }
    }
}
