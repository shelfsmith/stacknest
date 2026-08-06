// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// `booksNeedingFullCheck(mode:)` の候補クエリ（spec §4.3・Phase G27b Task 2）。
@Suite("full scan candidate query (G27b)")
struct IntegrityCandidateTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    private func book(id: Int, title: String, path: String) -> BookRow {
        BookRow(id: id, title: title, author: nil, genre: nil, path: path,
                dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0, pages: nil,
                rating: 0, unseen: false, keywordA: nil, keywordB: nil,
                keywordC: nil, neta: nil, memo: nil)
    }

    private func record(bookID: Int, status: IntegrityStatus, method: IntegrityMethod,
                        checkedAt: Int64) -> IntegrityRecord {
        IntegrityRecord(bookID: bookID, status: status, method: method, checkedAt: checkedAt,
                        fileSize: nil, fileMtime: nil, entryCount: nil, badEntries: [],
                        prevStatus: nil, prevCheckedAt: nil)
    }

    /// 4 冊を用意する: ①method='quick' の行のみ ②method='full' の行あり
    /// ③book_integrity 行なし ④status='damaged'（method='full' で damaged）。
    private func setupMixedLibrary() throws -> Database {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "quick-only", path: "/lib/1.zip"))
        try db.insertBook(book(id: 2, title: "full-ok", path: "/lib/2.zip"))
        try db.insertBook(book(id: 3, title: "no-row", path: "/lib/3.zip"))
        try db.insertBook(book(id: 4, title: "full-damaged", path: "/lib/4.zip"))

        try db.upsertIntegrity(record(bookID: 1, status: .ok, method: .quick, checkedAt: 100))
        try db.upsertIntegrity(record(bookID: 2, status: .ok, method: .full, checkedAt: 100))
        // book 3: 行なし
        try db.upsertIntegrity(record(bookID: 4, status: .damaged, method: .full, checkedAt: 100))

        return db
    }

    /// ★ 本タスクの核心: G27a の簡易チェック（method='quick'）を受けただけの本は、
    /// 詳細チェック（method='full'）をまだ受けていない ―― `.uncheckedOnly` はこれを
    /// 「未検査」として拾わなければならない。ここを「book_integrity に何か行があるか」で
    /// 判定してしまうと、簡易チェック済みの全冊が詳細スキャンの対象外になり、
    /// スキャンが何もしないまま終わる（brief が名指しした落とし穴）。
    @Test(".uncheckedOnly は method='full' の行が無い本を拾う（method='quick' しか無い本も含む）")
    func uncheckedOnlySelectsBooksWithoutFullRow() throws {
        let db = try setupMixedLibrary()

        let ids = Set(try db.booksNeedingFullCheck(mode: .uncheckedOnly).map(\.id))

        // 1 (quick のみ) と 3 (行なし) が対象。2 と 4 は既に full 行を持つので対象外。
        #expect(ids == [1, 3], "method='quick' しか無い本が未検査として拾えていない")
    }

    @Test(".all は method='full' の有無・status に関わらず全冊を返す")
    func allSelectsEveryBook() throws {
        let db = try setupMixedLibrary()

        let ids = Set(try db.booksNeedingFullCheck(mode: .all).map(\.id))

        #expect(ids == [1, 2, 3, 4])
    }

    @Test(".damagedOnly は status='damaged' の本だけを返す")
    func damagedOnlySelectsDamagedBooksOnly() throws {
        let db = try setupMixedLibrary()

        let ids = Set(try db.booksNeedingFullCheck(mode: .damagedOnly).map(\.id))

        #expect(ids == [4])
    }

    @Test(".damagedOnly は method を問わない（quick で damaged になった本も含む）")
    func damagedOnlyIncludesQuickDamagedBooks() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "quick-damaged", path: "/lib/1.zip"))
        try db.upsertIntegrity(record(bookID: 1, status: .damaged, method: .quick, checkedAt: 100))

        let ids = Set(try db.booksNeedingFullCheck(mode: .damagedOnly).map(\.id))

        #expect(ids == [1])
    }

    @Test(".uncheckedOnly は book_integrity に行が全く無いライブラリでは全冊を返す")
    func uncheckedOnlyOnFreshLibraryReturnsAllBooks() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))
        try db.insertBook(book(id: 2, title: "b", path: "/lib/b.zip"))

        let ids = Set(try db.booksNeedingFullCheck(mode: .uncheckedOnly).map(\.id))

        #expect(ids == [1, 2])
    }

    @Test("2 回目の full 走査後は .uncheckedOnly の候補が空になる")
    func uncheckedOnlyEmptiesAfterFullRowWritten() throws {
        let db = try setupDB()
        try db.insertBook(book(id: 1, title: "a", path: "/lib/a.zip"))
        #expect(try db.booksNeedingFullCheck(mode: .uncheckedOnly).map(\.id) == [1])

        try db.upsertIntegrity(record(bookID: 1, status: .ok, method: .full, checkedAt: 100))

        #expect(try db.booksNeedingFullCheck(mode: .uncheckedOnly).isEmpty)
    }
}
