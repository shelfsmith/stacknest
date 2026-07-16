// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// Codex review (G12b-3c): `restoreBook` must NOT clobber an unrelated book that has since
/// reused a freed id. `book.id` is `INTEGER PRIMARY KEY` without AUTOINCREMENT, so SQLite
/// reassigns a deleted row's id to the next inserted row. `restoreBook` switched from
/// "INSERT OR REPLACE" to a plain INSERT so such a collision throws instead of overwriting.
@Suite("Database.restoreBook id-reuse safety")
struct RestoreBookTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    /// id が未使用のまま解放されている通常ケース: restore は成功し、元の内容で復活する。
    @Test func restoresOntoFreeID() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "A"))
        let rowA = try #require(try db.fetchBook(id: 1))
        try db.deleteBook(id: 1)
        #expect(try db.fetchBook(id: 1) == nil)

        try db.restoreBook(rowA)

        let after = try #require(try db.fetchBook(id: 1))
        #expect(after.title == "A")
    }

    /// id が別の本に再利用された後の restore: エラーを投げ、再利用した本(B)を上書きしない。
    @Test func doesNotClobberBookThatReusedTheID() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "A"))
        let rowA = try #require(try db.fetchBook(id: 1))
        try db.deleteBook(id: 1)

        // id 1 が別の本(B)に再利用された状況をシミュレート（同じ id で新規本を挿入）。
        try db.insertBook(BookRow.testInstance(id: 1, title: "B"))

        #expect(throws: (any Error).self) {
            try db.restoreBook(rowA)
        }

        // B は生き残っている（A の内容で上書きされていない）。
        let after = try #require(try db.fetchBook(id: 1))
        #expect(after.title == "B")
    }
}
