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

    /// P2: insertBook(replace:)/restoreBook のいずれの経路でも
    /// cover_crop_rect / page_direction / content_hash / file_size / file_mtime の
    /// 5 列が失われず往復すること（delete-undo でのデータロス回帰防止）。
    @Test func restorePreservesAllColumns() throws {
        let db = try setupDB()
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let row = BookRow(id: 42, title: "T", author: "A", genre: nil, path: "/x/a.zip",
                          dateAdded: Date(timeIntervalSince1970: 1_700_000_000), playDate: nil,
                          bookType: 0, fileType: 0, pages: 10, rating: 3, unseen: false,
                          keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil,
                          series: "S", volume: 2,
                          coverImageName: "cover.jpg", coverCropRect: rect,
                          pageDirection: .rightToLeft, contentHash: "abc123", fileSize: 4096, fileMtime: 1_700_000_001)

        // 通常の insert 経路（replace 既定 true）。
        try db.insertBook(row)
        let got = try #require(try db.fetchBook(id: 42))
        #expect(got.coverCropRect == rect)
        #expect(got.pageDirection == .rightToLeft)
        #expect(got.contentHash == "abc123")
        #expect(got.fileSize == 4096)
        #expect(got.fileMtime == 1_700_000_001)

        // restore 経路（plain INSERT）でも同じく保持されること。
        try db.deleteBook(id: 42)
        try db.restoreBook(row)
        let restored = try #require(try db.fetchBook(id: 42))
        #expect(restored.coverCropRect == rect)
        #expect(restored.pageDirection == .rightToLeft)
        #expect(restored.contentHash == "abc123")
        #expect(restored.fileSize == 4096)
        #expect(restored.fileMtime == 1_700_000_001)
    }
}
