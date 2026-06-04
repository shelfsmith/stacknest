// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

// MARK: - per-book page direction (D1)

@Suite("Per-book page direction CRUD")
struct PageDirectionTests {

    // MARK: - DB setup helper

    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    // MARK: - (1) updateBook → leftToRight persists

    @Test func updatePageDirectionToLeftToRight() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBook(id: 1, patch: BookPatch(pageDirection: .leftToRight))
        let book = try db.fetchBook(id: 1)
        #expect(book?.pageDirection == .leftToRight)
    }

    // MARK: - (2) clearPageDirection → nil

    @Test func clearPageDirectionSetsNil() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        // 先に設定してから消す
        try db.updateBook(id: 1, patch: BookPatch(pageDirection: .rightToLeft))
        try db.updateBook(id: 1, patch: BookPatch(clearPageDirection: true))
        let book = try db.fetchBook(id: 1)
        #expect(book?.pageDirection == nil)
    }

    // MARK: - (3) fresh insert → nil

    @Test func freshlyInsertedBookHasNilPageDirection() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        let book = try db.fetchBook(id: 1)
        #expect(book?.pageDirection == nil)
    }

    // MARK: - (4) migration idempotency

    /// 同じ DB ファイルに migrate() を 2 回適用してもエラーにならないことを確認する。
    @Test func migrationIsIdempotent() throws {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mig-v14-idem-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let db1 = try Database.openExisting(at: { () -> URL in
            // 空ファイルを先に作って openExisting が通るようにする
            let db0 = try Database.openFile(at: tmpURL, mode: .createOrReplace)
            try db0.migrate()
            db0.close()
            return tmpURL
        }())
        // 2 回目の migrate() も throw しない
        try db1.migrate()
    }
}

// MARK: - Regression: page_direction survives searchBooks (FTS path, F1)
//         and nextVolumeInSeries / prevVolumeInSeries (F2)

@Suite("PageDirection survives search and series navigation")
struct PageDirectionSearchRegressionTests {

    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    // MARK: - F1: searchBooks (FTS trigram path, ≥3-char query) preserves pageDirection

    /// 3 文字以上のクエリは FTS trigram パスを通る。
    /// この経路で page_direction カラムが SELECT されていなければ常に nil が返る (F1 の再現条件)。
    @Test func ftsSearchPreservesPageDirection() throws {
        let db = try setupDB()
        // leftToRight を設定した book を挿入（updateBook で pageDirection を書き込む）
        try db.insertBook(BookRow.testInstance(id: 1, title: "ハイスコアガール第08巻"))
        try db.updateBook(id: 1, patch: BookPatch(pageDirection: .leftToRight))

        // FTS trigram を使う ≥3 文字クエリ
        let results = try db.searchBooks(query: "ハイスコア", sidebarScope: .library)
        #expect(results.count == 1)
        #expect(results.first?.pageDirection == .leftToRight,
                "FTS 検索結果の pageDirection が nil になっている (F1 の再現)")
    }

    // MARK: - F1: searchBooks (LIKE fallback path, 1-2-char query) preserves pageDirection

    @Test func likeSearchPreservesPageDirection() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "ATest"))
        try db.updateBook(id: 1, patch: BookPatch(pageDirection: .rightToLeft))

        // 1-2 文字クエリは LIKE fallback パスを通る
        let results = try db.searchBooks(query: "AT", sidebarScope: .library)
        #expect(results.count == 1)
        #expect(results.first?.pageDirection == .rightToLeft,
                "LIKE fallback 検索結果の pageDirection が nil になっている (F1 の再現)")
    }

    // MARK: - F2: nextVolumeInSeries preserves pageDirection

    @Test func nextVolumeInSeriesPreservesPageDirection() throws {
        let db = try setupDB()
        // 2 巻構成のシリーズを挿入
        try db.insertBook(BookRow(
            id: 1, title: "シリーズA 第1巻", author: nil, genre: nil, path: nil,
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil,
            memo: nil, series: "シリーズA", volume: 1.0
        ))
        try db.insertBook(BookRow(
            id: 2, title: "シリーズA 第2巻", author: nil, genre: nil, path: nil,
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil,
            memo: nil, series: "シリーズA", volume: 2.0
        ))
        // 第2巻に leftToRight を設定
        try db.updateBook(id: 2, patch: BookPatch(pageDirection: .leftToRight))

        let vol1 = try db.fetchBook(id: 1)!
        let next = try db.nextVolumeInSeries(after: vol1)
        #expect(next?.id == 2)
        #expect(next?.pageDirection == .leftToRight,
                "nextVolumeInSeries の pageDirection が nil になっている (F2 の再現)")
    }

    // MARK: - F2: prevVolumeInSeries preserves pageDirection

    @Test func prevVolumeInSeriesPreservesPageDirection() throws {
        let db = try setupDB()
        try db.insertBook(BookRow(
            id: 1, title: "シリーズB 第1巻", author: nil, genre: nil, path: nil,
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil,
            memo: nil, series: "シリーズB", volume: 1.0
        ))
        try db.insertBook(BookRow(
            id: 2, title: "シリーズB 第2巻", author: nil, genre: nil, path: nil,
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil,
            memo: nil, series: "シリーズB", volume: 2.0
        ))
        // 第1巻に rightToLeft を設定
        try db.updateBook(id: 1, patch: BookPatch(pageDirection: .rightToLeft))

        let vol2 = try db.fetchBook(id: 2)!
        let prev = try db.prevVolumeInSeries(before: vol2)
        #expect(prev?.id == 1)
        #expect(prev?.pageDirection == .rightToLeft,
                "prevVolumeInSeries の pageDirection が nil になっている (F2 の再現)")
    }
}

// MARK: - page direction resolution logic

/// グローバル設定と本ごと設定の解決ロジックを独立ヘルパ関数でテストする。
/// ViewerWindowController / AppState の実装では:
///   let resolvedDir = book.pageDirection ?? globalSetting
func resolvePageDirection(book: PageDirection?, global: PageDirection) -> PageDirection {
    book ?? global
}

@Suite("Page direction resolution")
struct PageDirectionResolutionTests {

    @Test func bookOverridesGlobal() {
        let result = resolvePageDirection(book: .leftToRight, global: .rightToLeft)
        #expect(result == .leftToRight)
    }

    @Test func nilBookInheritsGlobal() {
        let result = resolvePageDirection(book: nil, global: .rightToLeft)
        #expect(result == .rightToLeft)
    }

    @Test func nilBookInheritsGlobalLeftToRight() {
        let result = resolvePageDirection(book: nil, global: .leftToRight)
        #expect(result == .leftToRight)
    }
}
