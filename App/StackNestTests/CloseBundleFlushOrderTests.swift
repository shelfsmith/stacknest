// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
@testable import StackNest

/// G36 ③ Task 7: `closeBundle()` は「flush → backup → close」の順を守らないと、
/// バックアップ・オン・クローズが**フラッシュ前の古い設定**を掴んだまま DB をコピーする。
///
/// ## なぜこの順でしか検出できないか
///
/// `columnWidths` / `gridItemSize` / `windowFrame` は `SettingsWriteDebouncer` で 500ms
/// 遅延書き込みされる（G36 ③）。`flushPendingWrites()` を呼ばない限り、ディスク上の
/// `library_settings` テーブルには**まだ反映されていない**。`backupOnCloseIfNeeded()` は
/// その時点の DB ファイルをそのままコピーするため、flush より先に backup が走ると、
/// バックアップには保留中の値が欠落したまま焼き付く。
///
/// このテストは実際に `AppState.closeBundle()` を呼び、closeBundle が作ったバックアップ
/// ファイルを独立に開いて `columnWidths` の値を検査する。順序が入れ替わると
/// （`flushPendingWrites()` を `backupOnCloseIfNeeded()` より後や `database?.close()` の
/// 後に動かすと）このテストは FAIL する ―― flush 後の書き込みは閉じた DB では無音で
/// 捨てられるため、バックアップにも生きた DB にも値が残らない。
@Suite("closeBundle の flush→backup→close 順序（G36 ③ Task 7）")
@MainActor
struct CloseBundleFlushOrderTests {

    private func makeBundle() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g36-closebundle-\(UUID().uuidString).stacknest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 実ファイルの DB を持つ `AppState` を用意する。バックアップは実ファイルのコピーなので、
    /// in-memory DB では `BackupManager.changeCounter` / `db.backup(to:)` の実挙動を再現できない
    /// （`BackupManagerTests` と同じ理由でファイルベースにする）。
    private func makeState() throws -> (state: AppState, bundle: URL, db: Database) {
        let bundle = try makeBundle()
        let dbURL = bundle.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: dbURL, mode: .createOrReplace)
        try db.migrate()

        let settings = try LibrarySettings(database: db)
        settings.backupEnabled = true
        settings.backupGenerations = 5

        let state = AppState(bundleURL: bundle)
        state.database = db
        state.librarySettings = settings
        return (state, bundle, db)
    }

    /// ★ これが本命。デバウンス中（＝まだディスクに無い）の `columnWidths` が、
    /// `closeBundle()` が作るバックアップに**含まれている**こと。
    /// flush が backup より後ろに動くと、この検査は必ず落ちる。
    @Test("デバウンス中の columnWidths が closeBundle の作るバックアップに反映されている")
    func pendingColumnWidthsSurviveIntoTheBackup() throws {
        let (state, bundle, _) = try makeState()
        // 500ms のデバウンス中はまだディスクに無い状態を作る。
        state.librarySettings?.columnWidths = ["title": 271.5]
        #expect(state.librarySettings?.columnWidths["title"] == 271.5, "前提: メモリ上はすぐ更新される")

        state.closeBundle()

        let backups = BackupManager.list(in: BackupManager.backupsDir(for: bundle))
        let backupURL = try #require(backups.first, "closeBundle が backupOnCloseIfNeeded 経由でバックアップを 1 つ作ること")

        let backupDB = try Database.openExisting(at: backupURL)
        defer { backupDB.close() }
        let raw = try #require(try backupDB.getLibrarySetting(key: "columnWidths"),
                                "flush が backup より前に走っていれば columnWidths キーがバックアップに存在するはず")
        let decoded = try JSONDecoder().decode([String: Double].self, from: Data(raw.utf8))
        #expect(decoded["title"] == 271.5,
                "バックアップの columnWidths は flush 済みの値（271.5）であるべき ―― 順序が崩れていると欠落するか古い値のままになる")
    }

    /// closeBundle 自体は最後まで完走し、database / librarySettings を確実に手放す
    /// （flush 配線の追加が既存の後始末を壊していないことの確認）。
    @Test("closeBundle は最後まで完走して database と librarySettings を nil にする")
    func closeBundleStillTearsDownStateCompletely() throws {
        let (state, _, _) = try makeState()
        state.librarySettings?.columnWidths = ["title": 100]

        state.closeBundle()

        #expect(state.database == nil)
        #expect(state.librarySettings == nil)
    }
}
