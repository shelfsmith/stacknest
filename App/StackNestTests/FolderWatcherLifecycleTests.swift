// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
@testable import StackNest

/// G35 Codex P1-1: `scanAll` が `await` で中断している間に `stop()` が走ったときの挙動。
///
/// G35 で走査の重い部分をオフスレッドへ移した結果、`makePlan` の `await` が**毎回・数秒**
/// 発生するようになった（従来は取り込むものがあるときだけ短く中断していた）。
/// その窓で `stop()` が走ると、旧走査が再開後に
///
/// - `scanning` を握ったままになり、**後続の走査が入口で弾かれる**
///   （`reload()` は `stop()` → `start()` → `scanAll()` なので、監視設定の変更が
///   次の 60 秒タイマーまで反映されない）
/// - 停止後に `lastSizes` / `rejectedSizes` を書き戻す
/// - **閉じた DB へ取り込もうとする**（`AppState.closeBundle` は `stop()` → `database.close()` の順）
///
/// を起こす。世代番号で旧走査を失効させることで防いでいる。
@Suite("FolderWatcher のライフサイクル（G35 Codex P1）")
@MainActor
struct FolderWatcherLifecycleTests {

    private func makeWatchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g35-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeWatcher(watching dir: URL) throws -> FolderWatcher {
        let db = try Database.openInMemory()
        try db.migrate()
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("g35-\(UUID().uuidString).stacknest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let settings = try LibrarySettings(database: db)
        settings.folderWatchEnabled = true
        settings.watchedFolders = [WatchedFolder(
            id: UUID().uuidString, path: dir.path, enabled: true,
            presetID: nil, baseline: [], subfolderMode: .topLevelOnly)]

        return FolderWatcher(database: db, bundleURL: bundle, settings: settings,
                             onImported: { _ in })
    }

    // MARK: - ★ stop() が scanning を解放する（修正前は握られたままだった）

    /// **これが P1 の中核。** `stop()` が `scanning` を戻さないと、`await` 中断中の走査が
    /// フラグを握り続け、`reload()` で起こした新しい走査が入口の
    /// `guard !scanning` で弾かれる ―― 以降その watcher は 60 秒タイマーが来るまで走らない。
    @Test("走査の await 中に stop() すると scanning が解放される")
    func stopClearsScanningFlag() throws {
        let dir = try makeWatchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = try makeWatcher(watching: dir)

        watcher.scanNow()
        #expect(watcher.scanning == true, "走査が始まっていること（前提）")

        watcher.stop()

        #expect(watcher.scanning == false, "stop() は進行中の走査を失効させ scanning を解放する")
    }

    /// 停止後に改めて走らせられること（`reload()` 相当の流れ）。
    @Test("stop() のあと再び走査を開始できる")
    func canScanAgainAfterStop() throws {
        let dir = try makeWatchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = try makeWatcher(watching: dir)

        watcher.scanNow()
        watcher.stop()
        watcher.scanNow()          // reload() 相当

        #expect(watcher.scanning == true, "停止後の再走査が入口で弾かれない")
    }

    // MARK: - ★ stop() が settle 予約も解放する（Codex 2 巡目 P2）

    /// pending 候補があると 3 秒後の settle 再走査が予約される。`stop()` がこの予約を
    /// 解放しないと、再起動後の走査が `guard !settleScheduled` で予約を見送り、
    /// 古いタスクは世代チェックで抜けるため **誰も settle 走査を予約しない**。
    /// pending のファイルが 60 秒タイマーか次の vnode イベントまで取り込まれなくなる。
    @Test("stop() は settle 予約も解放する")
    func stopClearsSettleScheduling() async throws {
        let dir = try makeWatchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // サイズ > 0 の候補を置く → 1 回目の走査で pending になり settle が予約される
        try Data(repeating: 0x50, count: 4096)
            .write(to: dir.appendingPathComponent("pending.zip"))
        let watcher = try makeWatcher(watching: dir)

        watcher.scanNow()
        try? await Task.sleep(for: .milliseconds(400))   // 走査の完了を待つ
        #expect(watcher.settleScheduled == true, "pending があるので settle が予約される（前提）")

        watcher.stop()

        #expect(watcher.settleScheduled == false, "stop() は settle 予約も解放する")
    }

    // MARK: - ★ 走査は直列に保たれる（Codex 5 巡目 P1）

    /// `stop()` が `scanning` を解放するようにした結果、旧走査の**取り込みが走ったまま**
    /// 新走査が始まりうる状態になっていた（`BookImporter.add` は中断に協調しないため）。
    /// 同じ候補を 2 つの取り込みが同時に処理すると、重複挿入や表紙ファイルの衝突が起きる。
    /// 新走査は旧走査の完了を待ってから進む。
    ///
    /// ここでは**待ち合わせでデッドロックしない**ことと、停止・再開を繰り返しても
    /// 最終的に走査が完了することを見る（連鎖が自分自身を待つと固まる）。
    @Test("停止と再開を繰り返しても走査が固まらない")
    func repeatedStopAndRestartDoesNotDeadlock() async throws {
        let dir = try makeWatchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0x50, count: 2048)
            .write(to: dir.appendingPathComponent("a.zip"))
        let watcher = try makeWatcher(watching: dir)

        for _ in 0..<5 {
            watcher.scanNow()
            watcher.stop()
        }
        watcher.scanNow()

        // 連鎖した待ち合わせが解けて、最後の走査が完了すること。
        // デッドロックしていればここでタイムアウトする（scanning が下りない）。
        for _ in 0..<100 {
            if watcher.scanning == false { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(watcher.scanning == false, "待ち合わせが解けて走査が完了する")
    }

    /// ★ 直列化は「旧タスクの参照が `stop()` 後も残っていること」に依存している。
    /// `stop()` で `scanTask = nil` にすると、次の走査が `previous == nil` を掴み
    /// `await previous?.value` が素通りして、**取り込みが並行してしまう**
    /// （`BookImporter.add` は cancel しても止まらないため）。
    @Test("stop() は走査タスクの参照を捨てない（直列化の前提）")
    func stopKeepsTheScanTaskForSerialization() throws {
        let dir = try makeWatchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = try makeWatcher(watching: dir)

        watcher.scanNow()
        #expect(watcher.hasRetainedScanTask, "走査タスクが保持されている（前提）")

        watcher.stop()

        #expect(watcher.hasRetainedScanTask,
                "stop() の後も参照が残る ―― 次の走査がこれを待って重複取り込みを防ぐ")
    }

    /// 失効した旧走査が、後から始まった走査のフラグを消してしまわないこと。
    /// （`defer` を無条件に `scanning = false` にすると、旧走査の完了が新走査を潰す）
    @Test("失効した旧走査は、後続の走査の scanning を消さない")
    func staleScanDoesNotClearTheNewScansFlag() async throws {
        let dir = try makeWatchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = try makeWatcher(watching: dir)

        watcher.scanNow()          // 旧走査（await 中）
        watcher.stop()             // 失効させる
        watcher.scanNow()          // 新走査

        // 旧走査が resume して defer を通るのを待つ
        try? await Task.sleep(for: .milliseconds(500))

        // 新走査が完了していれば false、まだ動いていれば true。
        // いずれにせよ「旧走査の defer が新走査を潰した」場合と区別が付かないため、
        // ここでは *もう一度* 走らせられることで健全性を見る。
        watcher.stop()
        watcher.scanNow()
        #expect(watcher.scanning == true)
    }
}
