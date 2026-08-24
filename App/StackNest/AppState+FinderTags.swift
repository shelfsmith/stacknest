// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore
import OSLog

// Phase G39 Task 7: Finder タグ同期の起動と結果の提示。
//
// **この拡張はローカル庫（`AppState`）専用**。リモート庫は `RemoteLibraryState` が受け持つが、
// タグはサーバ機のファイルに付いておりクライアントからは触れないため、**リモートでは呼ばない**
// （spec §6）。メニュー項目もフォーカス中がローカル窓のときだけ有効になる。
//
// **StackNest 側の編集は即時に書き戻さない**（spec §5）。編集経路は UI / CLI(`stacknest-cli set`) /
// MCP(`stacknest_set`) / リモート共有サーバと 4 つあり、しかも**庫を閉じている間にも値は変わる**。
// 1 経路ずつ書き戻しを挿すと必ず漏れるので、**照合 1 本に集約**する ——
// 「庫を開いたとき」と「手動再照合」がその 1 本。
extension AppState {

    private static let finderTagLogger = Logger(subsystem: "app.shelfsmith.stacknest",
                                                category: "FinderTagSync")

    /// 手動再照合を今すぐ始められるか（メニュー項目の有効/無効）。
    var canStartFinderTagSync: Bool {
        database != nil && finderTagSyncField != nil && !isFinderTagSyncRunning
    }

    /// 同期対象の項目のユーザー向け表示名（ラベルカスタマイズを尊重する）。
    /// 未設定なら「メタデータ」。
    var finderTagSyncFieldLabel: String {
        guard let field = finderTagSyncField,
              let browseField = BrowserPaneState.BrowseField.allCases.first(where: { $0.sqlColumn == field })
        else { return String(localized: "メタデータ") }
        return librarySettings?.browseLabel(for: browseField) ?? field
    }

    /// 庫を開いたときに 1 回だけ呼ぶ。設定を読み込み、対象が決まっていれば同期を起こす。
    func loadFinderTagSyncSettingAndSyncOnce() {
        guard let db = database else { return }
        finderTagSyncField = FinderTagSyncSetting.current(db)
        startFinderTagSync(trigger: .libraryOpened)
    }

    /// 同期対象の項目を変更する（`nil` = 同期しない）。
    /// **前回同期値の全消しは `FinderTagSyncSetting.update` の中で行う**（そこが唯一の窓口）。
    func setFinderTagSyncField(_ field: String?) {
        guard let db = database else { return }
        do {
            try FinderTagSyncSetting.update(db, to: field)
            finderTagSyncField = FinderTagSyncSetting.current(db)
        } catch {
            self.error = .unexpected(error)
        }
    }

    /// 同期を**バックグラウンドで**1 回走らせる。
    ///
    /// ★ **メインスレッドを止めない**。12,000 冊で実測 0.41 秒だが、それは索引が効いていて
    /// ディスクが速いときの値で、`mdfind` の応答が遅い・壊れたタグが多いといくらでも伸びる。
    /// `Task.detached(priority: .utility)` を使うのは G34a/G35a-1 と同じ理由 ——
    /// **非構造 `Task {}` は呼び出し元（MainActor）の優先度を継承する**ので、
    /// 定期的な保守処理が user-interactive 相当で走ってしまう。
    /// - Parameter completion: 同期が**終わった**ところで結果を受け取る（CLI/MCP からの
    ///   再照合が「何件動いたか」を返せるようにするためのもの。UI は使わない）。
    ///   **`self` が消えていても必ず呼ばれる** —— 呼ばれないと待っている側が永久に待つ。
    /// - Returns: 始められたか、始められなかったならその理由。
    @discardableResult
    func startFinderTagSync(
        trigger: FinderTagSyncTrigger,
        completion: (@MainActor @Sendable (FinderTagSyncOutcome) -> Void)? = nil
    ) -> FinderTagSyncStart {
        guard !isFinderTagSyncRunning else {
            Self.finderTagLogger.debug("G39: sync already running; ignoring re-entry")
            return .alreadyRunning
        }
        guard let db = database else { return .noLibrary }
        guard let field = finderTagSyncField else {
            // 未設定（既定）は「同期しない」。庫を開いた契機では黙って何もしない。
            if trigger == .manual {
                presentFinderTagSyncNotice(FinderTagSyncNotice(
                    kind: .warning,
                    text: String(localized: "Finder タグと同期する項目が選ばれていません（ライブラリの設定で選べます）。"),
                    detail: nil))
            }
            return .noField
        }

        // ★ 施錠されたら手動再照合も止める。`canStartFinderTagSync` は
        // `database != nil && field != nil && !running` しか見ておらず、
        // **庫を開いた後に外部（CLI/MCP/共有サーバ/別窓）から施錠される**と
        // `needsUnlock` は true に戻るのに項目設定は残るため、メニューが有効なままだった。
        // 直したばかりの Critical と**同じ形**（ゲートが実作業の 1 段上にある）。
        guard !needsUnlock else { return .locked }

        isFinderTagSyncRunning = true
        // ★ 実際に走る子タスクを**保持して**おく。`Task.detached` の子には
        // 親 `Task` の `cancel()` が伝播しないので、外側だけを持っていても中断できない
        // （レビューが実測: `detached が見た isCancelled = false`）。
        // 中断できないと `FinderTagSyncRunner.run` の中断チェックが常に偽になり、
        // 庫を閉じても最後まで走り切る。
        let child = Task.detached(priority: .utility) {
            FinderTagSyncRunner.run(database: db, field: field)
        }
        finderTagSyncChild = child
        finderTagSyncTask = Task { @MainActor [weak self] in
            let outcome = await child.value
            // ★ **`self` を確かめる前に返す。**待っているのは CLI/MCP の HTTP ハンドラで、
            // 庫が閉じられて `AppState` が消えたときこそ結果を返さないと永久に待たせる
            // （中断で終わった場合も `FinderTagSyncRunner.run` は途中までの outcome を返す）。
            completion?(outcome)
            guard let self else { return }
            self.isFinderTagSyncRunning = false
            self.finderTagSyncTask = nil
            self.finderTagSyncChild = nil
            // 庫が閉じられていたら結果は捨てる（窓はもう無い）。
            guard self.database != nil else { return }
            if outcome.updatedInLibrary > 0 {
                do { try self.refreshDisplayedBooks() }
                catch { self.error = .unexpected(error) }
            }
            Self.finderTagLogger.info(
                "G39: sync done field=\(field, privacy: .public) lib=\(outcome.updatedInLibrary, privacy: .public) finder=\(outcome.updatedInFinder, privacy: .public) skippedTags=\(outcome.skippedTags.count, privacy: .public) skippedBooks=\(outcome.skippedBooks.count, privacy: .public) indexingDisabled=\(outcome.indexingDisabledVolumes.joined(separator: ","), privacy: .public)")
            if let notice = FinderTagSyncNotice.make(outcome: outcome, trigger: trigger,
                                                    fieldLabel: self.finderTagSyncFieldLabel) {
                self.presentFinderTagSyncNotice(notice)
            }
        }
        return .started
    }

    /// バナーを出す。**警告は自動で消さない** —— 索引無効やスキップは見逃したら分からなくなる。
    /// 変化の報告（info）だけ 6 秒で消す。
    func presentFinderTagSyncNotice(_ notice: FinderTagSyncNotice) {
        finderTagNoticeClearTask?.cancel()
        finderTagNoticeClearTask = nil
        finderTagSyncNotice = notice
        guard notice.kind == .info else { return }
        finderTagNoticeClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.finderTagSyncNotice = nil
        }
    }

    func dismissFinderTagSyncNotice() {
        finderTagNoticeClearTask?.cancel()
        finderTagNoticeClearTask = nil
        finderTagSyncNotice = nil
    }

    /// 庫を閉じるときの後始末（`closeBundle()` から呼ぶ）。
    func stopFinderTagSync() {
        // ★ **子（実際に走っている `Task.detached`）を先に止める。**
        // 親だけ cancel しても detached の子には伝播せず、中断チェックが効かない。
        finderTagSyncChild?.cancel()
        finderTagSyncChild = nil
        finderTagSyncTask?.cancel()
        finderTagSyncTask = nil
        finderTagNoticeClearTask?.cancel()
        finderTagNoticeClearTask = nil
        finderTagSyncNotice = nil
        isFinderTagSyncRunning = false
        finderTagSyncField = nil
    }
}
