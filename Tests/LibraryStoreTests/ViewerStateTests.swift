// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
import StackroomFormat

@Suite("Viewer state persistence (v13)")
struct ViewerStateTests {
    /// Inserts a book with series/volume and returns its new id.
    private func insertBook(
        _ db: Database,
        title: String,
        series: String?,
        volume: Double?
    ) throws -> Int {
        let rec = BookRecord(
            id: 0,
            title: title,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            series: series,
            volume: volume
        )
        return try db.insertBookReturningID(rec)
    }

    @Test("v13 creates the viewer-state tables")
    func tablesExist() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let tables = try db.fetchTableNames()
        #expect(tables.contains("book_viewer_state"))
        #expect(tables.contains("book_page_layout"))
        db.close()
    }

    @Test("loadViewerState returns defaults when no row")
    func loadDefaults() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "A", series: nil, volume: nil)
        let state = try db.loadViewerState(bookID: id)
        #expect(state.spreadEnabled == false)
        #expect(state.coverOffset == true)
        #expect(state.lastPage == 0)
        #expect(state.overrides.isEmpty)
        db.close()
    }

    @Test("saveViewerState then loadViewerState roundtrips")
    func saveLoadRoundtrip() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "A", series: nil, volume: nil)
        try db.saveViewerState(bookID: id, spreadEnabled: true, coverOffset: false, lastPage: 12)
        let state = try db.loadViewerState(bookID: id)
        #expect(state.spreadEnabled == true)
        #expect(state.coverOffset == false)
        #expect(state.lastPage == 12)
        // upsert: second save overwrites
        try db.saveViewerState(bookID: id, spreadEnabled: false, coverOffset: true, lastPage: 3)
        let state2 = try db.loadViewerState(bookID: id)
        #expect(state2.spreadEnabled == false)
        #expect(state2.lastPage == 3)
        db.close()
    }

    @Test("setPageOverride set then clear")
    func overrideSetClear() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "A", series: nil, volume: nil)
        try db.setPageOverride(bookID: id, page: 4, mode: 1)   // forceSolo
        try db.setPageOverride(bookID: id, page: 7, mode: 0)   // forcePair
        var state = try db.loadViewerState(bookID: id)
        #expect(state.overrides[4] == 1)
        #expect(state.overrides[7] == 0)
        // update existing
        try db.setPageOverride(bookID: id, page: 4, mode: 0)
        state = try db.loadViewerState(bookID: id)
        #expect(state.overrides[4] == 0)
        // clear with nil → removed
        try db.setPageOverride(bookID: id, page: 4, mode: nil)
        state = try db.loadViewerState(bookID: id)
        #expect(state.overrides[4] == nil)
        #expect(state.overrides[7] == 0)
        db.close()
    }

    @Test("nextVolumeInSeries normal next")
    func nextVolumeNormal() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id1 = try insertBook(db, title: "V1", series: "Saga", volume: 1.0)
        _ = try insertBook(db, title: "V2", series: "Saga", volume: 2.0)
        _ = try insertBook(db, title: "V3", series: "Saga", volume: 3.0)
        let v1 = try #require(try db.fetchBook(id: id1))
        #expect(v1.title == "V1")
        let next = try db.nextVolumeInSeries(after: v1)
        #expect(next?.title == "V2")
        db.close()
    }

    @Test("nextVolumeInSeries last volume returns nil")
    func nextVolumeLast() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        _ = try insertBook(db, title: "V1", series: "Saga", volume: 1.0)
        let id2 = try insertBook(db, title: "V2", series: "Saga", volume: 2.0)
        let v2 = try #require(try db.fetchBook(id: id2))
        #expect(try db.nextVolumeInSeries(after: v2) == nil)
        db.close()
    }

    @Test("nextVolumeInSeries decimal 1.5 ordering")
    func nextVolumeDecimal() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id1 = try insertBook(db, title: "V1", series: "Saga", volume: 1.0)
        _ = try insertBook(db, title: "V1.5", series: "Saga", volume: 1.5)
        _ = try insertBook(db, title: "V2", series: "Saga", volume: 2.0)
        let v1 = try #require(try db.fetchBook(id: id1))
        let next = try db.nextVolumeInSeries(after: v1)
        #expect(next?.title == "V1.5")
        db.close()
    }

    @Test("nextVolumeInSeries nil volume current returns nil")
    func nextVolumeNullCurrent() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let idA = try insertBook(db, title: "A", series: "Saga", volume: nil)
        _ = try insertBook(db, title: "B", series: "Saga", volume: 2.0)
        let a = try #require(try db.fetchBook(id: idA))
        #expect(try db.nextVolumeInSeries(after: a) == nil)
        db.close()
    }

    @Test("nextVolumeInSeries different series not returned")
    func nextVolumeDifferentSeries() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id1 = try insertBook(db, title: "S1V1", series: "Alpha", volume: 1.0)
        _ = try insertBook(db, title: "S2V2", series: "Beta", volume: 2.0)
        let s1v1 = try #require(try db.fetchBook(id: id1))
        #expect(try db.nextVolumeInSeries(after: s1v1) == nil)
        db.close()
    }

    @Test("nextVolumeInSeries same-volume id tiebreak")
    func nextVolumeSameVolumeTiebreak() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id1 = try insertBook(db, title: "V1", series: "Saga", volume: 1.0)
        let id2 = try insertBook(db, title: "V2a", series: "Saga", volume: 2.0)
        let id3 = try insertBook(db, title: "V2b", series: "Saga", volume: 2.0)
        #expect(id2 < id3)
        let v1 = try #require(try db.fetchBook(id: id1))
        let next = try db.nextVolumeInSeries(after: v1)
        #expect(next?.id == id2)   // lower id wins the tiebreak
        db.close()
    }

    @Test("deleteBook cascades and clears viewer state + page layout")
    func deleteCascadesViewerState() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "A", series: nil, volume: nil)
        try db.saveViewerState(bookID: id, spreadEnabled: true, coverOffset: false, lastPage: 7)
        try db.setPageOverride(bookID: id, page: 2, mode: 1)
        let before = try db.loadViewerState(bookID: id)
        #expect(before.spreadEnabled == true)
        #expect(before.lastPage == 7)
        #expect(before.overrides[2] == 1)
        // FK ON DELETE CASCADE (PRAGMA foreign_keys = ON) should clear both
        // book_viewer_state and book_page_layout rows for this book.
        try db.deleteBook(id: id)
        let after = try db.loadViewerState(bookID: id)
        #expect(after == StoredViewerState())   // all defaults + empty overrides ⇒ both rows gone
        db.close()
    }

    // MARK: - T5: spreadByDefault resolution semantics

    /// 行なし（初回オープン）の場合、hasPersistedState == false を返すことを確認する。
    /// App 層の resolvedState はこれを見て spreadByDefault を使う。
    @Test("loadViewerState returns hasPersistedState=false for book with no row")
    func loadViewerStateNoPersistFlag() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "NoState", series: nil, volume: nil)
        let loaded = try db.loadViewerState(bookID: id)
        #expect(loaded.hasPersistedState == false, "行なし → hasPersistedState == false")
        #expect(loaded.spreadEnabled == false, "行なし → デフォルト spread=false")
        #expect(loaded.lastPage == 0)
        db.close()
    }

    /// saveViewerState 後は hasPersistedState == true を返すことを確認する。
    @Test("loadViewerState returns hasPersistedState=true after save")
    func loadViewerStatePersistedFlag() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "HasState", series: nil, volume: nil)
        try db.saveViewerState(bookID: id, spreadEnabled: true, coverOffset: false, lastPage: 0)
        let loaded = try db.loadViewerState(bookID: id)
        #expect(loaded.hasPersistedState == true, "行あり → hasPersistedState == true")
        #expect(loaded.spreadEnabled == true, "保存済み spreadEnabled=true は維持される")
        db.close()
    }

    /// 保存済み spread=false の本は spreadByDefault=true でも false のまま（ユーザー設定尊重）。
    @Test("loadViewerState returns persisted spreadEnabled=false — App must not override with global default")
    func persistedSpreadFalseNotOverridden() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "HasStateFalse", series: nil, volume: nil)
        try db.saveViewerState(bookID: id, spreadEnabled: false, coverOffset: true, lastPage: 0)
        let loaded = try db.loadViewerState(bookID: id)
        #expect(loaded.hasPersistedState == true, "行あり → hasPersistedState == true")
        // App 層は hasPersistedState==true なので spreadByDefault を無視し false を使う。
        #expect(loaded.spreadEnabled == false, "保存済み spread=false は維持される")
        db.close()
    }

    // MARK: - Phase 4.1a: bulk viewer-state fetch for the library server

    /// fetchAllViewerStates が保存済みの本だけを last_page / updated_at 付きで返すことを確認する。
    @Test("fetchAllViewerStates returns last pages and updatedAt only for persisted books")
    func fetchAllViewerStatesReturnsLastPagesAndUpdatedAt() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let book1ID = try insertBook(db, title: "A", series: nil, volume: nil)
        let book2ID = try insertBook(db, title: "B", series: nil, volume: nil)
        try db.saveViewerState(bookID: book1ID, spreadEnabled: false, coverOffset: true, lastPage: 5)
        let states = try db.fetchAllViewerStates()
        #expect(states[book1ID]?.lastPage == 5)
        #expect(states[book1ID]?.updatedAt != nil)
        #expect(states[book2ID] == nil)
        db.close()
    }

    /// updateLastPage は last_page / updated_at のみ更新し、spread_enabled /
    /// cover_offset の既存値を壊さない。行が無い本には既定値で INSERT する。
    @Test("updateLastPage preserves viewer flags and inserts when missing")
    func updateLastPagePreservesViewerFlags() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let b = try insertBook(db, title: "A", series: nil, volume: nil)
        let b2 = try insertBook(db, title: "B", series: nil, volume: nil)
        try db.saveViewerState(bookID: b, spreadEnabled: true, coverOffset: false, lastPage: 3)
        try db.updateLastPage(bookID: b, lastPage: 7)
        let s = try db.loadViewerState(bookID: b)
        #expect(s.lastPage == 7)
        #expect(s.spreadEnabled == true)    // 保持
        #expect(s.coverOffset == false)     // 保持
        // 未存在の本にも INSERT できる
        try db.updateLastPage(bookID: b2, lastPage: 1)
        #expect(try db.loadViewerState(bookID: b2).lastPage == 1)
        // updated_at も刻印される（fetchAllViewerStates 経由で確認）
        #expect(try db.fetchAllViewerStates()[b2]?.updatedAt != nil)
        db.close()
    }

    // MARK: - G17 T6a: spread_explicit — progress-only rows must not be trusted as explicit spread

    /// v17 migration adds `spread_explicit` to book_viewer_state and existing rows default to 0.
    /// Simulates a pre-v17 row (as if written by an older binary's saveViewerState) by inserting
    /// directly, then re-running migrate() and confirming the column exists with the row at 0.
    // 注: v17 の ALTER＋backfill（既存行の明示判定）そのものは、pre-v17 スキーマを直接組める
    // MigrationV17Tests.swift（GRDB 直）で検証する。ここでは公開 API 経由の挙動のみ確認する。
    @Test("v17: progress-only row keeps spread_explicit=0; re-migrate is idempotent")
    func progressOnlyRowStaysNonExplicitAndMigrateIsIdempotent() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "Pre-v17", series: nil, volume: nil)
        // progress-only writeback（updateLastPage）だけ = DEFAULT のまま。
        try db.updateLastPage(bookID: id, lastPage: 4)
        let loaded = try db.loadViewerState(bookID: id)
        #expect(loaded.hasPersistedState == true)
        #expect(loaded.spreadExplicit == false, "progress-only 行は spread_explicit=0 のまま")
        // migrate() 再実行は冪等（ALTER TABLE ADD COLUMN を二度実行しない）。
        try db.migrate()
        #expect(try db.loadViewerState(bookID: id).spreadExplicit == false)
        db.close()
    }

    /// (a) 本が「progress のみ書かれた」（Web リーダーの writeback = updateLastPage 経由）状態では、
    /// loadViewerState は spread_explicit=false を返す。App 層の resolvedState はこれを見て
    /// spreadByDefault にフォールバックすべきで、DB の spreadEnabled（SQLite DEFAULT 0）を
    /// 信用してはならない（G17 T6a: Web 既読本がネイティブで単ページ化するリークの回帰防止）。
    @Test("progress-only row (updateLastPage) never sets spread_explicit")
    func progressOnlyRowDoesNotSetSpreadExplicit() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "WebReadOnly", series: nil, volume: nil)
        // No saveViewerState call at all — only the remote progress writeback path.
        try db.updateLastPage(bookID: id, lastPage: 42)
        let loaded = try db.loadViewerState(bookID: id)
        #expect(loaded.hasPersistedState == true, "行は作られる")
        #expect(loaded.spreadExplicit == false, "progress-only 行は明示設定とみなさない")
        #expect(loaded.spreadEnabled == false, "SQLite DEFAULT 0 が入るだけで意味を持たない値")
        #expect(loaded.lastPage == 42, "last_page は正しく反映される")
        db.close()
    }

    /// updateLastPage を先に呼んだ後で saveViewerState（明示保存）を呼ぶと、以後は
    /// spread_explicit=1 に切り替わる（後から明示設定した場合の正しい昇格）。
    @Test("saveViewerState after progress-only row upgrades spread_explicit to true")
    func explicitSaveAfterProgressOnlyUpgradesFlag() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "LaterExplicit", series: nil, volume: nil)
        try db.updateLastPage(bookID: id, lastPage: 5)
        #expect(try db.loadViewerState(bookID: id).spreadExplicit == false)
        try db.saveViewerState(bookID: id, spreadEnabled: true, coverOffset: true, lastPage: 5)
        let loaded = try db.loadViewerState(bookID: id)
        #expect(loaded.spreadExplicit == true, "明示保存後は spread_explicit=1 に昇格する")
        #expect(loaded.spreadEnabled == true)
        db.close()
    }

    /// (b) 明示保存で spread=false にした本は、spread_explicit=true として DB 値（false）を
    /// そのまま維持する（progress writeback とは別に、真のユーザー意図として記録される）。
    @Test("explicit save with spread=false resolves spread_explicit=true, spreadEnabled=false")
    func explicitSaveFalseSetsExplicitFlag() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "ExplicitFalse", series: nil, volume: nil)
        try db.saveViewerState(bookID: id, spreadEnabled: false, coverOffset: true, lastPage: 0)
        let loaded = try db.loadViewerState(bookID: id)
        #expect(loaded.spreadExplicit == true)
        #expect(loaded.spreadEnabled == false)
        // その後 progress のみの更新が来ても spread_explicit / spreadEnabled は変わらない。
        try db.updateLastPage(bookID: id, lastPage: 9)
        let after = try db.loadViewerState(bookID: id)
        #expect(after.spreadExplicit == true, "progress 更新後も明示フラグは保持される")
        #expect(after.spreadEnabled == false, "progress 更新後も spread 値は保持される")
        #expect(after.lastPage == 9)
        db.close()
    }

    /// (c) 明示保存で spread=true にした本は、spread_explicit=true として DB 値（true）を維持する
    /// （既存の「'd' キーで見開き ON にした本を尊重する」挙動の回帰がないことを確認）。
    @Test("explicit save with spread=true resolves spread_explicit=true, spreadEnabled=true")
    func explicitSaveTrueSetsExplicitFlag() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "ExplicitTrue", series: nil, volume: nil)
        try db.saveViewerState(bookID: id, spreadEnabled: true, coverOffset: true, lastPage: 0)
        let loaded = try db.loadViewerState(bookID: id)
        #expect(loaded.spreadExplicit == true)
        #expect(loaded.spreadEnabled == true)
        db.close()
    }

    @Test("prevVolumeInSeries normal + first volume nil")
    func prevVolume() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id1 = try insertBook(db, title: "V1", series: "Saga", volume: 1.0)
        let id2 = try insertBook(db, title: "V2", series: "Saga", volume: 2.0)
        let v2 = try #require(try db.fetchBook(id: id2))
        let prev = try db.prevVolumeInSeries(before: v2)
        #expect(prev?.title == "V1")
        let v1 = try #require(try db.fetchBook(id: id1))
        #expect(try db.prevVolumeInSeries(before: v1) == nil)
        db.close()
    }
}
