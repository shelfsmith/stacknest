// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
import RemoteClient
@testable import StackNest

/// `IntegrityWindowLogic` の純関数テスト（Phase G27b Task 6）。
///
/// **ここでテストできるのはウィンドウの表示ロジックだけ**（brief の制約）。
/// 実 `NSWindow` を作る `IntegrityCheckView`/`IntegrityWindowContainer` 自体は App テストで
/// インスタンス化しない — 実 NSWindow を作る App テストはテストホストをクラッシュさせる
/// （測定済み: 13 passing → 0 with "Restarting after unexpected exit"）。
/// 劣化判定そのもの（`IntegrityRecord.isDegraded`）は既に
/// `Tests/LibraryStoreTests/IntegrityStoreTests.swift` でテスト済みのため、ここでは重複させず
/// 「ウィンドウ固有」のロジック（要約文言・表示順・完了メッセージ・ボタン→モードの対応）だけを扱う。
@Suite("IntegrityWindowLogic (G27b Task 6)")
struct IntegrityWindowLogicTests {
    // Phase G29 Task 1: `sortedForDisplay` の引数が `(book: BookRow, record: IntegrityRecord)` の
    // タプルから `IntegrityRow` に変わったため、テストのフィクスチャもそれに合わせる。
    // 並び替え条件（劣化優先 → 検査が新しい順 → タイトル順）自体は変わっていない。
    private func row(id: Int64, title: String, checkedAt: Int64 = 0, degraded: Bool = false) -> IntegrityRow {
        IntegrityRow(id: id, title: title, filename: "\(id).zip", path: "/tmp/\(id).zip",
                     status: .damaged, checkedAt: Date(timeIntervalSince1970: TimeInterval(checkedAt)),
                     entryCount: nil, badEntries: [], degraded: degraded)
    }

    // MARK: - ScanAction → FullScanMode

    @Test("3 つのボタンはそれぞれ異なる FullScanMode に対応する")
    func scanActionMapsToDistinctModes() {
        #expect(IntegrityWindowLogic.ScanAction.uncheckedOnly.mode == .uncheckedOnly)
        #expect(IntegrityWindowLogic.ScanAction.all.mode == .all)
        #expect(IntegrityWindowLogic.ScanAction.damagedOnly.mode == .damagedOnly)
    }

    @Test("確認が要るのは「全件やり直し」だけ")
    func onlyAllRequiresConfirmation() {
        #expect(IntegrityWindowLogic.ScanAction.uncheckedOnly.needsConfirmation == false)
        #expect(IntegrityWindowLogic.ScanAction.all.needsConfirmation == true)
        #expect(IntegrityWindowLogic.ScanAction.damagedOnly.needsConfirmation == false)
    }

    // MARK: - scanButtonDisabled（Phase G29 Task 3 review fix Critical 2）
    //
    // `IntegrityCheckView` は実 NSWindow を作るため App テストでインスタンス化できない
    // （ファイル冒頭のコメント参照）。ビューが実際に `.disabled(...)` へ渡す条件式そのものを
    // ここに切り出したので、「tier ゲートがボタンの有効/無効に実際に効くか」をここで縛る。

    @Test("実行中でなく tier も足りていれば有効（無効化されない）")
    func scanButtonEnabledWhenIdleAndAuthorized() {
        #expect(IntegrityWindowLogic.scanButtonDisabled(isScanning: false, canStartScan: true) == false)
    }

    @Test("tier が足りなければ、実行中でなくても無効")
    func scanButtonDisabledWhenNotAuthorized() {
        #expect(IntegrityWindowLogic.scanButtonDisabled(isScanning: false, canStartScan: false) == true)
    }

    @Test("実行中は tier が足りていても無効")
    func scanButtonDisabledWhileScanning() {
        #expect(IntegrityWindowLogic.scanButtonDisabled(isScanning: true, canStartScan: true) == true)
    }

    @Test("実行中かつ tier も足りない場合も無効")
    func scanButtonDisabledWhileScanningAndNotAuthorized() {
        #expect(IntegrityWindowLogic.scanButtonDisabled(isScanning: true, canStartScan: false) == true)
    }

    // MARK: - summaryLineText（Phase G29 Task 3 fix round 2, Critical: 破損 0 件を偽装しない）
    //
    // 実際にビューが描画するのはこの関数の戻り値であって `summaryLine` 単体ではない
    // （`IntegrityCheckView.body` は `summaryLineText(...)` の結果が nil なら何も描画しない）。
    // 「読み込み失敗のときに件数を出さない」という配線そのものをここで縛る。

    @Test("読み込みエラーが無ければ summaryLine と同じ文字列を返す")
    func summaryLineTextReturnsLineWhenNoError() {
        let summary = IntegritySummary(checked: 90, unchecked: 10, damaged: 3, degraded: 1)
        let text = IntegrityWindowLogic.summaryLineText(summary: summary, lastScanAt: nil, loadErrorText: nil)
        #expect(text == IntegrityWindowLogic.summaryLine(summary: summary, lastScanAt: nil))
    }

    @Test("読み込みエラーがあれば、件数が全 0 のフォールバック値でも nil を返す（描画しない）")
    func summaryLineTextSuppressedWhenLoadFailed() {
        // reload() のフォールバック規律どおり、失敗時の summary は初回だと全 0 になる。
        // その状態でエラーが立っているとき、summaryLineText は「破損 0 冊」を出してはいけない。
        let zeroSummary = IntegritySummary(checked: 0, unchecked: 0, damaged: 0, degraded: 0)
        let text = IntegrityWindowLogic.summaryLineText(
            summary: zeroSummary, lastScanAt: nil, loadErrorText: "この庫は施錠されています。")
        #expect(text == nil)
    }

    // MARK: - remoteFailureMessage（Phase G29 Task 3 fix round 2: reload/startScan/jobProgress 共通）

    @Test("libraryLocked は専用の文言になる（呼び出し側の context は使われない）")
    func remoteFailureMessageForLibraryLocked() {
        let message = IntegrityWindowLogic.remoteFailureMessage(
            for: RemoteClientError.libraryLocked, context: "読み込みに失敗しました。")
        #expect(message.contains("施錠"))
        #expect(!message.contains("読み込みに失敗しました"))
    }

    @Test("libraryLocked 以外は呼び出し側の context をそのまま使う")
    func remoteFailureMessageForOtherErrorsUsesContext() {
        #expect(IntegrityWindowLogic.remoteFailureMessage(
            for: RemoteClientError.server(403), context: "読み込みに失敗しました。") == "読み込みに失敗しました。")
        #expect(IntegrityWindowLogic.remoteFailureMessage(
            for: RemoteClientError.server(403), context: "スキャンを開始できませんでした。") == "スキャンを開始できませんでした。")
        #expect(IntegrityWindowLogic.remoteFailureMessage(
            for: RemoteClientError.offline, context: "進捗を取得できません。") == "進捗を取得できません。")
    }

    // MARK: - summaryLine

    @Test("未検査（一度もスキャンしていない）の要約文言")
    func summaryLineWhenNeverScanned() {
        let summary = IntegritySummary(checked: 0, unchecked: 10, damaged: 0, degraded: 0)
        let line = IntegrityWindowLogic.summaryLine(summary: summary, lastScanAt: nil)
        #expect(line.contains("最終検査: 未検査"))
        #expect(line.contains("未検査 10 冊"))
        #expect(line.contains("破損 0 冊"))
        #expect(line.contains("劣化 0 冊"))
    }

    @Test("検査済みなら最終検査日時が入り、各件数がそのまま反映される")
    func summaryLineWhenScanned() {
        let summary = IntegritySummary(checked: 90, unchecked: 10, damaged: 3, degraded: 1)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let line = IntegrityWindowLogic.summaryLine(summary: summary, lastScanAt: date)
        #expect(!line.contains("最終検査: 未検査"))
        #expect(line.contains(IntegrityWindowLogic.formattedDate(date)))
        #expect(line.contains("未検査 10 冊"))
        #expect(line.contains("破損 3 冊"))
        #expect(line.contains("劣化 1 冊"))
    }

    // MARK: - completionSummary

    @Test("完走した場合は検査数と破損数を出す")
    func completionSummaryOnFullRun() {
        let report = FullScanReport(scanned: 120, byStatus: [.ok: 115, .damaged: 5],
                                    persistenceFailures: 0, cancelled: false)
        let text = IntegrityWindowLogic.completionSummary(report)
        #expect(text.contains("完了"))
        #expect(text.contains("120"))
        #expect(text.contains("5"))
        #expect(!text.contains("中断"))
    }

    @Test("中断した場合は完了ではなく中断の文言になる")
    func completionSummaryOnCancellation() {
        let report = FullScanReport(scanned: 40, byStatus: [.ok: 40],
                                    persistenceFailures: 0, cancelled: true)
        let text = IntegrityWindowLogic.completionSummary(report)
        #expect(text.contains("中断"))
        #expect(text.contains("40"))
        #expect(!text.contains("完了"))
    }

    @Test("保存失敗があれば件数を明示する")
    func completionSummaryMentionsPersistenceFailures() {
        let report = FullScanReport(scanned: 10, byStatus: [.ok: 9],
                                    persistenceFailures: 2, cancelled: false)
        #expect(IntegrityWindowLogic.completionSummary(report).contains("保存失敗 2 件"))
    }

    // MARK: - sortedForDisplay（劣化を先頭に）

    @Test("劣化行が非劣化行より先頭に来る")
    func degradedRowsSortFirst() {
        let rows: [IntegrityRow] = [
            row(id: 1, title: "Zoo", checkedAt: 100, degraded: false),
            row(id: 2, title: "Apple", checkedAt: 200, degraded: true),
        ]
        let sorted = IntegrityWindowLogic.sortedForDisplay(rows)
        #expect(sorted.first?.id == 2, "劣化（prevStatus=ok→damaged）が先頭に来るべき")
        #expect(sorted.first?.degraded == true)
    }

    @Test("劣化どうしは検査が新しい順")
    func degradedRowsSortByMostRecentFirst() {
        let rows: [IntegrityRow] = [
            row(id: 1, title: "Old", checkedAt: 100, degraded: true),
            row(id: 2, title: "New", checkedAt: 300, degraded: true),
        ]
        let sorted = IntegrityWindowLogic.sortedForDisplay(rows)
        #expect(sorted.map(\.id) == [2, 1])
    }

    @Test("非劣化どうしはタイトルの辞書順")
    func nonDegradedRowsSortByTitle() {
        let rows: [IntegrityRow] = [
            row(id: 1, title: "Zebra", checkedAt: 100, degraded: false),
            row(id: 2, title: "Apple", checkedAt: 200, degraded: false),
        ]
        let sorted = IntegrityWindowLogic.sortedForDisplay(rows)
        #expect(sorted.map(\.id) == [2, 1])
    }
}
