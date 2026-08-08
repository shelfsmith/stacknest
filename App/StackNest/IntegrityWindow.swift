// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import Foundation
import LibraryServerAPI
import LibraryStore
import RemoteClient
import SwiftUI

// Phase G27b Task 6: 整合性チェックウィンドウ。
//
// **これは独立ウィンドウであり、シート (.sheet) ではない。これはスタイルの好みではない。**
// フルスキャンは最大約 31 時間かかりうる（spec §4.1）。AppKit は添付シートがある間
// `terminate:` を実行しない（`applicationShouldTerminate` にすら到達しない）ため、進捗表示を
// シートにすると、スキャンが終わるまでアプリを終了できなくなる。G27c は解錠 UI が全く同じ理由で
// シート起因の "-128 で終了できない" 不具合を踏んでおり（この事故は本プロジェクトのビルド手順を
// 3 回止めた）、同じ轍を踏まないためここでは:
//   - ウィンドウ登録は `WindowGroup(for:)`（`StackNestApp.swift` の `RemoteLibraryRef` と同じ形）。
//   - ウィンドウ内の確認（「全件やり直し」開始前など）も `.sheet`/`.confirmationDialog` ではなく
//     `NSAlert().runModal()`（window に添付しない app-modal）を使う。BookDeleteCommand・
//     RelinkSheet が既にこの形で確認ダイアログを出しており、それに揃えている。

// MARK: - 表示ロジック（View から分離してテスト可能にする）

/// 整合性チェックウィンドウの純粋な表示ロジック。`NSWindow` を作らずにテストできる部分はここに置く
/// （brief: 「劣化判定・件数の要約文言」）。`IntegrityRecord.isDegraded` 自体は LibraryStore 側で
/// 既にテスト済みなので、ここではその上に乗る「ウィンドウ固有」のロジック（要約文言・表示順・
/// 完了メッセージ・ボタン→モードの対応）だけを扱う。
enum IntegrityWindowLogic {
    /// 3 つのスキャンボタンと `FullScanMode` の対応。
    enum ScanAction: String, CaseIterable, Identifiable, Sendable {
        case uncheckedOnly
        case all
        case damagedOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .uncheckedOnly: return "未検査をスキャン"
            case .all: return "全件やり直し"
            case .damagedOnly: return "破損のみ再検査"
            }
        }

        var mode: FullScanMode {
            switch self {
            case .uncheckedOnly: return .uncheckedOnly
            case .all: return .all
            case .damagedOnly: return .damagedOnly
            }
        }

        /// 「全件やり直し」は spec §4.1 のとおり最大約 31 時間かかりうる規模の操作のため、
        /// 開始前に確認する。他の 2 つは対象が未検査/破損のみに絞られており確認は不要。
        var needsConfirmation: Bool { self == .all }
    }

    /// スキャン開始ボタンの無効化条件。実行中、または（リモートで tier が admin 未満などの理由で）
    /// `canStartScan == false` のとき無効。
    ///
    /// Phase G29 Task 3 review fix (Critical 2): `IntegrityCheckView` は実 `NSWindow` を作るため
    /// App テストでインスタンス化できない（測定済み: 13 passing → 0 with "Restarting after
    /// unexpected exit"、本ファイル冒頭の `IntegrityWindowLogicTests` のコメント参照）。
    /// ビューが実際に使う無効化条件をここへ切り出すことで、「tier ゲートがビューの有効/無効に
    /// 実際に効いているか」をユニットテストできるようにする（`IntegrityCheckView` 側は
    /// このメソッドを呼ぶだけの 1 行に保ち、二重の判定ロジックを持たない）。
    static func scanButtonDisabled(isScanning: Bool, canStartScan: Bool) -> Bool {
        isScanning || !canStartScan
    }

    /// 「最終検査」欄の文言。`isKnown == false` は「そもそも取得できない」（リモート）ケースで、
    /// 「未検査」（一度も検査していない、という既知の事実）とは区別する。
    ///
    /// Phase G29 Task 3 fix round 4 (Important 1, whole-branch review): `lastScanAt == nil` は
    /// これまで無条件に「未検査」と表示していたが、リモートでは `integrity/summary` が最終検査
    /// 時刻を運ばないため常に nil ―― フルスキャン済みのリモート庫でも「最終検査: 未検査
    /// 破損 3 冊」という自己矛盾した断言になっていた。「取得できない」と「一度もしていない」は
    /// 別の答えなので、`isKnown` で分岐する。
    static func lastScanText(_ lastScanAt: Date?, isKnown: Bool) -> String {
        guard isKnown else { return "不明（リモートでは取得できません）" }
        return lastScanAt.map(formattedDate) ?? "未検査"
    }

    /// 概要行（brief: 「最終検査 / 未検査 N 冊 / 破損 N 冊 / 劣化 N 冊」）。
    static func summaryLine(
        summary: IntegritySummary, lastScanAt: Date?, lastScanAtIsKnown: Bool = true, now: Date = Date()
    ) -> String {
        let last = lastScanText(lastScanAt, isKnown: lastScanAtIsKnown)
        return "最終検査: \(last)　未検査 \(summary.unchecked) 冊　破損 \(summary.damaged) 冊　劣化 \(summary.degraded) 冊"
    }

    /// `summaryLine` を表示してよいかどうかの判定込みの版。`loadErrorText != nil`（読み込み失敗）
    /// のときは nil を返し、呼び出し側は何も表示しない。
    ///
    /// Phase G29 Task 3 fix round 2 (Critical, review 再指摘): `summary` の失敗フォールバックは
    /// 「前回値を保持」で、初回読み込みでは `IntegritySummary(0,0,0,0)`。これを無条件に描画すると、
    /// 施錠庫でエラーラベルのすぐ上に「破損 0 冊」という**読めなかったことについての積極的な
    /// 安全宣言**が出てしまう（Critical 1 で一覧側は直したが、この行は直っていなかった）。
    /// 「破損している本はありません。」を `loadErrorText == nil` のときだけ出す判断と対にする。
    static func summaryLineText(
        summary: IntegritySummary, lastScanAt: Date?, lastScanAtIsKnown: Bool = true, loadErrorText: String?
    ) -> String? {
        guard loadErrorText == nil else { return nil }
        return summaryLine(summary: summary, lastScanAt: lastScanAt, lastScanAtIsKnown: lastScanAtIsKnown)
    }

    /// リモートエラーの表示文言。`RemoteClientError.libraryLocked` は「施錠されていて未解錠」という
    /// 一級市民のケース（`RemoteClientError.swift:19-23` のコメント参照）なので専用の文言、
    /// それ以外は呼び出し側が渡す文脈依存の汎用文言（「読み込みに失敗しました。」
    /// 「スキャンを開始できませんでした。」等）を使う。
    ///
    /// Phase G29 Task 3 fix round 2: `reload()`（読み込み失敗）と `startScan()`（開始失敗）の
    /// 両方から使う共通ヘルパとして切り出した。`IntegrityCheckView` は実 NSWindow を作るため
    /// App テストでインスタンス化できない制約があるので、ビューが実際に呼ぶこの関数を
    /// `IntegrityWindowLogic`（既に `NSWindow` を作らない純ロジック置き場）に置き、
    /// テスト対象そのものにする。
    ///
    /// Phase G29 Task 3 fix round 4 (whole-branch review C1): 施錠メッセージに「解錠後は更新」を
    /// 明示するよう追記した。以前は「解錠してください」とだけ言っていたが、`RemoteIntegrityDataSource`
    /// が値をスナップショットしていたため解錠しても窓が自力で追従せず、**指示に従っても直らない**
    /// 状態だった。live-state 化（fix round 4）で次の読み込みは新しいトークンを使うようになった
    /// ため、「更新を押す」までを指示に含めることで、指示どおりに操作すれば実際に直るようにする。
    static func remoteFailureMessage(for error: Error, context: String) -> String {
        if case RemoteClientError.libraryLocked = error {
            return "この庫は施錠されています。庫のウィンドウで解錠してから「更新」を押してください。"
        }
        // fix round 6 (whole-branch review NEW-4): 庫のウィンドウが閉じられて権限を確認できない状態。
        // 「取得に失敗した」ではなく「聞きに行く前提が崩れている」ので、促す操作も再試行ではなく更新。
        if case RemoteIntegrityUnavailable.permissionUnconfirmed = error {
            return "庫のウィンドウが閉じられているため、状態を確認できません。庫を開き直してから「更新」を押してください。"
        }
        // Codex レビュー(Important): サーバが running=true と言いながら進捗の内訳を返さなかった。
        // 0/0 を確定値として描かず、取得できなかったことをそのまま言う。
        if case RemoteIntegrityUnavailable.progressIncomplete = error {
            return "サーバが進捗の内訳を返しませんでした。"
        }
        return context
    }

    /// 進捗キャプションに付ける「最終取得」注記。`stale == true`（＝直近の `jobProgress()` 取得が
    /// 失敗し、`jobStatus` が凍結されている）のときだけ非空文字列を返す。
    ///
    /// Phase G29 Task 3 fix round 3 (Minor, review 再々指摘): 接続が切れている間も凍結した
    /// `jobStatus` の done/total をそのまま出し続けると、あたかも今も更新されているかのように
    /// 読める。隣に出る `progressErrorText` は警告として気づかれるとは限らないため、
    /// 数字そのものにも「最新ではないかもしれない」を明示する。
    static func staleSuffix(stale: Bool) -> String {
        stale ? "（最終取得の値）" : ""
    }

    static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// 「取得: HH:MM」用の時刻のみのフォーマット。
    ///
    /// fix round 5 (Minor, whole-branch review): 画面上のどこにもデータの鮮度を示す手掛かりが
    /// 無かった。read/edit 接続が他の接続によるスキャン完了を静かに見ている間、「破損している
    /// 本はありません。」も「最終検査: 不明」も**いつの時点の情報かを言わない**現在形の断言に
    /// 見えてしまう。更新ボタンの隣にこの時刻を出すことで、「これは取得できた時点の情報」と
    /// 明示する。
    static func formattedTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// スキャン完了後の 1 行メッセージ。中断か完走かで文言を変える。
    static func completionSummary(_ report: FullScanReport) -> String {
        if report.cancelled {
            return "中断しました（\(report.scanned) 件検査済み）"
        }
        let damaged = report.byStatus[.damaged] ?? 0
        if report.persistenceFailures > 0 {
            return "完了: \(report.scanned) 件検査 / 破損 \(damaged) 件（保存失敗 \(report.persistenceFailures) 件）"
        }
        return "完了: \(report.scanned) 件検査 / 破損 \(damaged) 件"
    }

    /// File メニュー「ファイルの破損チェック…」の有効化条件（2026-08-08 smoke フィードバック由来）。
    ///
    /// - **ローカル**: 常に有効。
    /// - **リモート**: **解錠済み（`!locked`）かつ tier が admin のときのみ**有効。
    ///   - 施錠中は `remoteState` 自体は non-nil のまま（解錠フォームを表示するため）なので、
    ///     従来は項目が有効なままだった。隣の「重複を検出…」は `target?.canEditMeta`
    ///     （`target` は施錠中 nil）でグレーアウトしており、それと一貫させる。
    ///   - read/edit 接続は `POST .../integrity/full-scan` が admin 専用のため、開いても
    ///     スキャンを一切開始できない。閲覧専用モードは提供しない方針（ユーザー選定）なので、
    ///     ウィンドウそのものへの入口を隠す。
    ///
    /// tier は `/me` 解決前は `.read` 既定（fail-closed）のため、接続直後は一旦グレーのまま、
    /// `/me` 完了後に有効化される ―― これは許容される想定挙動。
    ///
    /// ウィンドウを開いたあとに tier が変化/確認不能になるケース（`canStartScan`/
    /// `scanUnavailableReason`）はこの関数のスコープ外 ―― ここは「メニュー項目を出すかどうか」
    /// だけを決める。ウィンドウ内の安全網は変更しない。
    /// - Parameter remote: `lockedOut` は **「今ロックアウトされている（解錠フォームが出ている）」**。
    ///   `RemoteLibraryState.locked` を**そのまま渡してはいけない** ―― あれは「パスワードが
    ///   設定されている」の意味で、`unlock(password:)` は `libraryToken` を入れるだけで
    ///   `locked` を落とさないため、そのまま使うとパスワード付きの庫が解錠後も永久に無効になる
    ///   （2026-08-08 のレビューで Critical として検出。ヘルパだけをテストしていたため
    ///   呼び出し側の引数の誤りを素通りさせた）。呼び出し側は
    ///   `RemoteLibraryView.isUnlockFormShown` と同じ `locked && libraryToken == nil` を渡すこと。
    /// `RemoteLibraryState` の生の値から `lockedOut` を導く。
    ///
    /// **この導出自体をテスト可能にするために切り出してある。** 2026-08-08 のレビューは、
    /// ヘルパ（`canOpenIntegrityCheckWindow`）だけをテストしていたために
    /// **呼び出し側が `locked` をそのまま渡している誤りを素通りさせた**と指摘した。
    /// 判定の一部だけをテスト可能にしても、テストされていない側に誤りが移るだけである。
    static func remoteLockedOut(locked: Bool, libraryToken: String?) -> Bool {
        // `RemoteLibraryView.isUnlockFormShown` と同じ式。`locked` 単体は
        // 「パスワードが設定されている」であって「今ロックアウトされている」ではない。
        locked && libraryToken == nil
    }

    static func canOpenIntegrityCheckWindow(hasLocalLibrary: Bool, remote: (lockedOut: Bool, tier: AccessTier)?) -> Bool {
        if hasLocalLibrary { return true }
        guard let remote else { return false }
        return !remote.lockedOut && remote.tier >= .admin
    }

    /// 一覧の表示順: 劣化（前回 ok → 今回 damaged）を先頭に、劣化どうしは検査が新しい順。
    /// それ以外はタイトル順。「今回悪化した本」をスクロールなしで見つけられるようにするための
    /// ウィンドウ固有の並び替えロジック（`Database.integrityRecords` 自体はタイトル順で返す）。
    ///
    /// Phase G29 Task 1: `(book: BookRow, record: IntegrityRecord)` タプルから `IntegrityRow` へ
    /// 引数の型が変わった（データ源をローカル/リモートで差し替えられるようにするための「形の変更」
    /// ―― リモートの `IntegrityItemDTO` には `BookRow`/`IntegrityRecord` 自体が存在しないため）。
    /// 並び替えの判定条件そのもの（劣化優先 → 検査が新しい順 → タイトル順）は変えていない。
    static func sortedForDisplay(_ rows: [IntegrityRow]) -> [IntegrityRow] {
        rows.sorted { a, b in
            if a.degraded != b.degraded { return a.degraded }
            if a.degraded {
                return (a.checkedAt ?? .distantPast) > (b.checkedAt ?? .distantPast)
            }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

// MARK: - IntegrityCheckRef / WindowGroup container

/// 整合性チェックウィンドウを開くための値型（`WindowGroup(for:)` のキー）。
/// ローカル庫は `bundleURL` で、リモート庫は `RemoteLibraryRef` と同じ `(serverID, libraryUUID)` で
/// 一意に識別する。
///
/// Phase G29 Task 3: 単なる `struct { bundleURL: URL }` から enum 化した。ローカル/リモートで
/// 「庫を一意に識別する値」の形そのものが異なるため（リモートにはバンドルファイルが無い）。
enum IntegrityCheckRef: Codable, Hashable {
    case local(bundleURL: URL)
    case remote(serverID: UUID, libraryUUID: String)
}

/// `IntegrityCheckRef` を解決し、対応する庫のデータ源が用意できたら `IntegrityCheckView` を
/// 表示するコンテナ。`RemoteLibraryWindowContainer` と同じ「参照値から state を解決するコンテナ」
/// パターンを踏襲する。
///
/// - `.local`: 同一プロセス内で既に開いている `AppState`（`AppState.activeInstances`）から
///   `bundleURL` が一致するものを探す（Task 1 から変更なし）。ローカル DB を直接読むため、
///   Finder 表示に必要な実パスもここでのみ手に入る。
/// - `.remote`: まず `RemoteLibraryRegistry.shared.allObjects`（`ResumeLastReadCoordinator.swift:51`
///   と同じ確立パターン、`.local` の `AppState.activeInstances` と対称）で「既に開いている
///   ブラウズウィンドウの `RemoteLibraryState`」を探す。見つかれば `libraryToken`/`tier` を
///   解決し直さず（施錠庫でも解錠済みトークンをそのまま使える）そのまま使う。無ければ
///   `RemoteLibraryWindowContainer.resolve()` と同じ `ServerConnectionStore` フォールバックへ
///   落ちる（この経路では施錠庫の `libraryToken` を持てないため、読み込みが 403 になりうる。
///   `IntegrityCheckView.reload()` 側でエラー表示する ―― review Critical 1）。
struct IntegrityWindowContainer: View {
    let ref: IntegrityCheckRef
    /// Phase G29 Task 3 review fix (Minor 5): `RemoteLibraryWindowContainer` と同じく
    /// `private let store` として保持する（メソッド内で毎回 `ServerConnectionStore()` を作らない）。
    private let store = ServerConnectionStore()

    @State private var localAppState: AppState?
    @State private var notFound = false
    /// Phase G29 Task 1 review fixup: データ源を `body` の中で毎回新規生成すると、`body` が
    /// 再評価されるたびにインスタンスの identity が変わり、ローカルではスキャン中の再評価で
    /// `pendingReportBox`（自分が開始したジョブの詳細）が新インスタンスには無いため完了
    /// キャプションが黙って消える。`resolve()` で 1 回だけ生成し `@State` に保持することで、
    /// ウィンドウの寿命と identity を一致させる（`resolve()` 自体も `dataSource == nil` の間しか
    /// 実行しない一回性のガードを持つ）。
    @State private var dataSource: IntegrityDataSource?

    var body: some View {
        Group {
            if let dataSource, let payload = readyPayload {
                IntegrityCheckView(
                    bundleURL: payload.bundleURL, database: payload.database, appState: payload.appState,
                    dataSource: dataSource, refreshDataSource: refreshRemoteDataSource)
            } else if notFound {
                missingView
            } else {
                ProgressView()
                    .frame(minWidth: 400, minHeight: 300)
            }
        }
        // ローカルは同期解決だが、リモートは HTTP 呼び出しを伴いうるため `resolve()` 全体を
        // async にしてある（`RemoteLibraryWindowContainer` と同じ `.task { await resolve() }`）。
        .task { await resolve() }
    }

    /// fix round 5 (Critical, whole-branch review — 「shape 2」): `.remote` のときだけ、
    /// 「更新」ボタンから呼べる再解決クロージャを渡す。`RemoteIntegrityDataSource` の
    /// `liveState`（弱参照）がブラウズ窓のクローズで nil になった後は `tierResolutionFailed` で
    /// 正直に「確認できない」と言うだけで、それ自体は直らない ―― **本当に直すには
    /// `resolveRemoteDataSource` をもう一度呼び、新しい（生きている）state を掴み直す必要がある**。
    /// これが無いと「更新を押してください」という案内が実際には何も直さない、
    /// 同じ「指示に従っても直らない」欠陥の再演になる。
    private var refreshRemoteDataSource: (@MainActor () async -> IntegrityDataSource?)? {
        guard case .remote(let serverID, let libraryUUID) = ref else { return nil }
        return { await Self.resolveRemoteDataSource(serverID: serverID, libraryUUID: libraryUUID, store: store) }
    }

    /// Phase G29 Task 3 review fix (Important 4): `body` 評価のたびに評価する computed property。
    /// `.local` では `localAppState?.database`（`AppState` は `@Observable`）をここで読むことで
    /// Observation 依存を張り直す ―― これが無いと（Task 3 で `if let appState, let database =
    /// appState.database, let dataSource` という旧来の body ガードを崩したことで）、ウィンドウを
    /// 開いたままローカル庫を閉じても（`AppState.close()` が `database = nil` にしても）body が
    /// 再評価されず、閉じた `Database` を読み続けたまま「破損 0 件」を表示し続けてしまっていた
    /// （review Important 4）。`bundleURL` も `ref` から直接取るようにし、`@State` での二重保持を
    /// やめた（`ref` は `let` で不変なので、`.local(bundleURL:)` の値は常に最新）。
    /// `.remote` には「ウィンドウの外側から閉じられる」という対応する概念が無いため、
    /// `dataSource` が用意できていれば常に表示してよい。
    private var readyPayload: (bundleURL: URL?, database: Database?, appState: AppState?)? {
        switch ref {
        case .local(let bundleURL):
            guard let localAppState, let database = localAppState.database else { return nil }
            return (bundleURL, database, localAppState)
        case .remote:
            return (nil, nil, nil)
        }
    }

    private var missingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(missingText)
                .font(.headline)
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }

    private var missingText: String {
        switch ref {
        case .local: return "ライブラリが開かれていません"
        case .remote: return "サーバが見つかりません。再接続してください"
        }
    }

    private func resolve() async {
        guard dataSource == nil, notFound == false else { return }
        switch ref {
        case .local(let bundleURL):
            resolveLocal(bundleURL: bundleURL)
        case .remote(let serverID, let libraryUUID):
            await resolveRemote(serverID: serverID, libraryUUID: libraryUUID)
        }
    }

    private func resolveLocal(bundleURL: URL) {
        if let match = AppState.activeInstances.allObjects.first(where: { $0.bundleURL.path == bundleURL.path }) {
            localAppState = match
            // `AppState.finishOpening()` は `database`/`librarySettings` を同期的に設定してから
            // `activeInstances` へ登録する（`AppState.swift` 参照）ため、`activeInstances` から
            // 見つかった時点で `match.database` は必ず non-nil。
            if let database = match.database {
                dataSource = LocalIntegrityDataSource(database: database, bundleURL: bundleURL, appState: match)
            }
        } else {
            notFound = true
        }
    }

    @MainActor
    private func resolveRemote(serverID: UUID, libraryUUID: String) async {
        if let ds = await Self.resolveRemoteDataSource(serverID: serverID, libraryUUID: libraryUUID, store: store) {
            dataSource = ds
        } else {
            notFound = true
        }
    }

    /// fix round 4/5 (whole-branch review C1): `resolveRemote()` の中身を `self` への代入から
    /// 切り離した版。初回解決にも「更新」ボタンからの再解決にも同じロジックを使う ――
    /// 弱参照（`RemoteIntegrityDataSource.liveState`）が死んだ後も、更新を押せば
    /// **本当に**回復できるようにするため（fix round 4 で「更新してください」と案内するように
    /// なったが、その時点では再解決の仕組みが無く、案内どおりに押しても直らなかった＝再指摘）。
    @MainActor
    private static func resolveRemoteDataSource(
        serverID: UUID, libraryUUID: String, store: ServerConnectionStore
    ) async -> IntegrityDataSource? {
        // review Critical 1 → fix round 4: まず、同じ庫を既に開いているブラウズウィンドウの
        // `RemoteLibraryState` を探す。見つかればその state を弱参照で `RemoteIntegrityDataSource` に
        // 渡す ―― `libraryToken`/`tier` を値としてコピーしない（fix round 3 まではここで
        // スナップショットしていたため、解錠しても `/me` が完了しても窓に反映されなかった）。
        if let liveState = RemoteLibraryRegistry.shared.allObjects.first(where: {
            $0.serverID == serverID && $0.libraryUUID == libraryUUID
        }) {
            return RemoteIntegrityDataSource(client: liveState.client, libraryUUID: libraryUUID, liveState: liveState)
        }
        // フォールバック: `RemoteLibraryWindowContainer.resolve()` と同じ `ServerConnectionStore`
        // パターン（ブラウズウィンドウが無い状態で integrity ウィンドウだけが復元された場合等）。
        // `libraryToken` を持てないため、施錠庫では `summary`/`list` が 403(libraryLocked) になりうる
        // ―― `IntegrityCheckView.reload()` 側でエラー表示する。
        guard let conn = store.connection(id: serverID),
              let base = URL(string: conn.baseURL) else {
            return nil
        }
        let client = RemoteLibraryClient(baseURL: base, deviceToken: conn.token)
        // `/me` はデバイストークンの tier（grant 由来）を返す。ライブラリの施錠状態とは無関係
        // （施錠は `libraryToken` 側の話）なので、`libraryToken: nil` のままで解決できる。
        // 呼び出し自体が失敗した場合（オフライン等）は `tierResolutionFailed` を立てて渡す ――
        // 「権限が無い」と「権限を確認できない」は原因が違うため、ビューに出す理由文言を分ける
        // （review Minor 4）。
        let meResult = try? await client.me(libraryToken: nil)
        return RemoteIntegrityDataSource(
            client: client, libraryUUID: libraryUUID, libraryToken: nil,
            tier: meResult?.tier ?? .read, tierResolutionFailed: meResult == nil)
    }
}

// MARK: - IntegrityCheckView

/// 整合性チェックウィンドウの本体。開いた時点では**スキャンを走らせず**、保存済みの結果
/// （`Database.integritySummary()` / `integrityRecords(status:)`）を即表示する。
struct IntegrityCheckView: View {
    /// Phase G29 Task 3: ローカル庫のみ non-nil（リモートにはバンドルファイルが無い）。
    let bundleURL: URL?
    /// Phase G29 Task 3: ローカル庫のみ non-nil。relink/delete は「ローカルにしか受け側が無い」
    /// 操作（`BrowserCommandTarget.canManageLocalFiles` と同じ理由）なので、リモートでは
    /// `database == nil` を見て行メニューごと無効化する。
    let database: Database?
    var appState: AppState?
    /// fix round 5 (Critical, whole-branch review): `let` から `@State var` にした。「更新」で
    /// リモートのデータ源そのものを取り替えられるようにするため ―― `RemoteIntegrityDataSource` の
    /// `liveState`（弱参照）が死んだ後は、同じインスタンスを読み直しても「確認できない」から
    /// 抜け出せない。取り替えると、以後 `reload()`/`startObserving()` など `self.dataSource` を
    /// 読むすべての箇所が `@State` の共有ストレージ経由で新しい値を見るようになる
    /// （`pollTask` のクロージャも含む ―― 明示的な再起動は不要）。
    @State private var dataSource: IntegrityDataSource
    /// fix round 5: `.remote` のときのみ non-nil。「更新」がリモートのデータ源を再解決できるように
    /// `IntegrityWindowContainer` から渡される（`.local` では re-resolve の概念が無いので nil）。
    let refreshDataSource: (@MainActor () async -> IntegrityDataSource?)?

    @State private var summary = IntegritySummary(checked: 0, unchecked: 0, damaged: 0, degraded: 0)
    @State private var lastScanAt: Date?
    @State private var rows: [IntegrityRow] = []
    // G27b 最終レビュー Fix2/Fix4: ウィンドウは `MaintenanceJobRegistry` の状態を**観測**するだけで、
    // 自前のタスク/フラグを所有しない。`jobStatus` は「今このライブラリで走っているジョブ」を
    // ポーリングで反映したもので、GUI が開始したかどうかを問わない（CLI/MCP・他ウィンドウが
    // 開始したジョブも同じフィールドに映る）。これにより:
    //   - ウィンドウを閉じてもジョブは registry 側で走り続ける（scanTask を持たないので
    //     「唯一の参照を失って中断できなくなる」が構造的に起こらない＝Fix4）。
    //   - 再度開けば `.onAppear` の最初のポーリングで即座に isScanning=true に復帰する。
    // Phase G29 Task 1: 型を `MaintenanceJobRegistry.JobStatus?` から `IntegrityJobProgress?`
    // （データ源プロトコルの戻り値型）へ変更。ポーリング先が registry 直読みからプロトコル
    // 越しの `dataSource.jobProgress()` に変わっただけで、意味・使われ方は変えていない。
    @State private var jobStatus: IntegrityJobProgress?
    @State private var lastReport: FullScanReport?
    @State private var pollTask: Task<Void, Never>?
    /// Phase G29 Task 3 review fix (Critical 1): `reload()` が `summary`/`lastScanAt`/`list` の
    /// いずれかで例外を捕まえたら、その理由をここに残す。non-nil の間は「破損している本は
    /// ありません。」という積極的な安全宣言も、要約行の件数も出さない ―― 読めなかったことと
    /// 破損が無いことは区別しなければならない（fix round 2 で要約行にも適用）。
    @State private var loadErrorText: String?
    /// Phase G29 Task 3 fix round 2 (Critical, review 再指摘・同族): `startScan()` が busy（409→false）
    /// ではない例外を捕まえたら、その理由をここに残す。busy は正常系（次のポーリングで反映）だが、
    /// 403 等は「開始に失敗した」という別の状態であり、黙って何も起きないことにしてはいけない。
    @State private var scanErrorText: String?
    /// Phase G29 Task 3 fix round 2 (Minor, review 再指摘・同族): `dataSource.jobProgress()` の
    /// 取得自体が失敗したら、その理由をここに残す。`jobStatus` は直前の値を保持したまま
    /// （＝「止まった」と勝手に判定しない）、取得できていないことを別途表示する。
    @State private var progressErrorText: String?
    /// Phase G29 Task 3 fix round 4 (whole-branch review C1): `dataSource.canStartScan`/
    /// `scanUnavailableReason` を body で直接読まず、`@State` にコピーしてポーリングのたびに
    /// 更新する。`dataSource` は `@Observable` ではない protocol 型なので、body 内で直接読んでも
    /// SwiftUI は「あとで値が変わったら再描画する」依存を張れない ―― リモートの `tier` は
    /// 解錠・`/me` 完了で後から変わりうる（`RemoteIntegrityDataSource` が live-state を弱参照する
    /// ように直した）ため、その変化を実際に画面へ反映するにはこの `@State` コピーが要る。
    /// 初期値は `init` で `dataSource` から同期的に読む（ネットワークを伴わない）。
    @State private var canStartScan: Bool
    @State private var scanUnavailableReason: String?
    /// fix round 5 (Minor, whole-branch review): 最後に `reload()` が**成功**した時刻。
    /// 失敗時は更新しない（画面上のデータは古い成功時点のものであり続けるため、
    /// スタンプもそれに合わせて古いままにする）。
    @State private var lastRefreshedAt: Date?

    /// `canStartScan`/`scanUnavailableReason` の初期値を `dataSource` から同期的に読むためだけの
    /// 明示的な `init`（`@State` の initial value は宣言時の定数式にできないため）。
    init(bundleURL: URL?, database: Database?, appState: AppState? = nil, dataSource: IntegrityDataSource,
         refreshDataSource: (@MainActor () async -> IntegrityDataSource?)? = nil) {
        self.bundleURL = bundleURL
        self.database = database
        self.appState = appState
        _dataSource = State(initialValue: dataSource)
        self.refreshDataSource = refreshDataSource
        _canStartScan = State(initialValue: dataSource.canStartScan)
        _scanUnavailableReason = State(initialValue: dataSource.scanUnavailableReason)
    }

    private var isScanning: Bool { jobStatus != nil }
    private var progress: (done: Int, total: Int) { (jobStatus?.done ?? 0, jobStatus?.total ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ファイルの破損チェック")
                    .font(.title2.bold())
                Spacer()
                // fix round 5 (Minor, whole-branch review): データの鮮度を明示する。
                // 「破損している本はありません。」等の現在形の表示が、実は数分前の取得結果である
                // 可能性を隠さない。
                if let lastRefreshedAt {
                    Text("取得: \(IntegrityWindowLogic.formattedTime(lastRefreshedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // fix round 4 (whole-branch review C1 / I2): 手動更新。施錠庫を解錠した後・
                // 他の接続がスキャンを完了させた後に、この窓が自力で復帰する導線が無かった
                // （閉じて開き直す以外に手段が無かった）。⌘R で `reload()` と権限表示の両方を
                // 即座にやり直す。fix round 5: リモートでは `refreshDataSource` があれば
                // データ源そのものも取り替える（弱参照が死んでいた場合の**本当の**回復手段）。
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("更新（解錠・権限確定・他の接続によるスキャン完了を反映します）")
                .keyboardShortcut("r", modifiers: .command)
            }
            // review Critical (fix round 2, Critical 1 の同族): 読み込みが失敗しているときは
            // 件数を出さない。`summary` の失敗フォールバックは「前回値を保持」（初回は全 0）なので、
            // 無条件描画するとエラー表示の真上に「破損 0 冊」という偽の安全宣言が出てしまっていた。
            // fix round 4 (Important 1): `lastScanAtIsKnown` にデータ源の申告を渡し、
            // リモートでは「未検査」ではなく「不明」と出す。
            if let line = IntegrityWindowLogic.summaryLineText(
                summary: summary, lastScanAt: lastScanAt,
                lastScanAtIsKnown: dataSource.supportsLastScanAt, loadErrorText: loadErrorText) {
                Text(line)
                    .foregroundStyle(.secondary)
            }

            HStack {
                ForEach(IntegrityWindowLogic.ScanAction.allCases) { action in
                    Button(action.title) { requestScan(action) }
                        // review Critical 2: tier ゲートを消費する。`.disabled(isScanning)` だけでは
                        // read/edit 接続でもボタンが有効なままで、押すと 403 が `startScan` の
                        // `try?` に握り潰され「何も起きない」になっていた（spec §3.4・受け入れ基準 3）。
                        // 判定そのものは `IntegrityWindowLogic.scanButtonDisabled` に切り出してあり
                        // （テスト可能にするため）、ここはそれを呼ぶだけに保つ。fix round 4: 直接
                        // `dataSource.canStartScan` を読まず、ポーリングで更新される `@State` を使う
                        // （tier の変化を実際に再描画へ反映するため。上のコメント参照）。
                        .disabled(IntegrityWindowLogic.scanButtonDisabled(
                            isScanning: isScanning, canStartScan: canStartScan))
                }
                Spacer()
                if isScanning {
                    Button("中断") { cancelScan() }
                }
            }
            // review Critical 2: `.help()`（ホバーしないと見えない）ではなく、常に見える形で理由を
            // 出す。tier が足りる（`scanUnavailableReason == nil`）間は何も出さない。
            if let reason = scanUnavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let loadErrorText {
                // review Critical 1: 読み込み自体が失敗している。破損 0 件/一覧空という積極的な
                // 「安全」表示より先に、読めなかった事実を出す。
                Label(loadErrorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let scanErrorText {
                // fix round 2 (Critical, Critical 1 の同族): スキャン開始が busy 以外の理由で
                // 失敗した（例: 施錠庫に admin トークンで、ブラウズウィンドウ無しの
                // ServerConnectionStore フォールバック経路から到達）。
                Label(scanErrorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let progressErrorText {
                // fix round 2 (Minor, Critical 1 の同族): 進捗の取得自体に失敗している。
                // 直前の `jobStatus` は保持したままなので、それが最新ではない可能性を明示する。
                Label(progressErrorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if isScanning {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                // fix round 3 (Minor, review 再々指摘): 進捗取得が失敗中（`progressErrorText != nil`）
                // は、凍結された done/total が最新ではない可能性を「最終取得の値」で明示する。
                let stale = IntegrityWindowLogic.staleSuffix(stale: progressErrorText != nil)
                if jobStatus?.isIntegrityFullScan == true {
                    Text("検査中… \(progress.done)/\(progress.total)\(stale)")
                        .font(.caption)
                        .monospacedDigit()
                } else {
                    // 同じライブラリで他のメンテナンスジョブ（表紙圧縮・メタ補完等）が実行中。
                    // registry は庫あたり同時 1 本しか許さないため、ここのボタンも busy として
                    // 無効化する（誤って別ジョブの done/total を「検査」として誤読させない）。
                    Text("他のメンテナンス処理を実行中です（\(jobStatus?.job ?? "")）… \(progress.done)/\(progress.total)\(stale)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if let lastReport {
                Text(IntegrityWindowLogic.completionSummary(lastReport))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // review Critical 1: 「破損している本はありません。」は**読めたときだけ**出してよい
            // 積極的な安全宣言。`loadErrorText != nil`（読み込み失敗）のときは、一覧が空でも
            // このメッセージを出さない（読めなかっただけかもしれないため）。
            if rows.isEmpty, loadErrorText == nil {
                Spacer()
                HStack {
                    Spacer()
                    Text("破損している本はありません。")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else if !rows.isEmpty {
                List(rows) { row in
                    rowView(row)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 560)
        .onAppear {
            // Phase G29 Task 1 review fixup: `reload()` は今は async なので fire-and-forget の
            // `Task` に包んでいる（旧実装は同期呼び出しで `startObserving()` の前に完走していた）。
            // この 2 つは互いに独立でよい ―― `startObserving()` は `jobStatus` だけを進捗ポーリングで
            // 埋め、`reload()` は `summary`/`rows`/`lastScanAt` を埋める。どちらが先に終わっても
            // 相手の結果を読まない。最悪ケースは reload 完了までの数フレーム、要約/一覧が
            // 初期値のまま表示される程度で、不変条件（Fix2/Fix4・ジョブ検出）には影響しない。
            Task { @MainActor in await reload() }
            startObserving()
        }
        .onDisappear {
            // Fix4: ここで registry のジョブを中断してはいけない ―― ウィンドウはジョブの
            // オブザーバであってオーナーではない。閉じるのはこのビューのポーリングだけ。
            pollTask?.cancel()
            pollTask = nil
        }
    }

    @ViewBuilder
    private func rowView(_ row: IntegrityRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if row.degraded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("劣化: 前回は正常だった本が壊れています（ビット腐敗の疑い）")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .fontWeight(row.degraded ? .semibold : .regular)
                // review Important 3: `filename` はリモートでも DTO の basename が入っている
                // （`path` はローカルのみ）。`path` が無ければ `filename` にフォールバックする ――
                // 従来は `path` しか見ておらず、リモートの全行が「タイトル＋『—』」になっていた。
                Text(row.path ?? row.filename ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.badEntries.isEmpty {
                    Text(row.badEntries.prefix(3).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            Spacer()
            if row.degraded {
                Text("劣化")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
            }
            Menu {
                // Phase G29 Task 1: リモートでは `row.path` が nil になるため無効化する
                // （brief: 「Finder で表示」ボタンは path == nil で出し分ける）。
                Button("Finder で表示") { revealInFinder(row) }
                    .disabled(row.path == nil)
                // Phase G29 Task 3: リモートには relink/delete の受け側が無い
                // （`BrowserCommandTarget.canManageLocalFiles` と同じ理由）ので、`database == nil`
                // （＝リモート庫）のとき無効化する。
                Button("再リンク…") { relink(row) }
                    .disabled(database == nil)
                Button("ライブラリから削除", role: .destructive) { delete(row) }
                    .disabled(database == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.vertical, 4)
        .listRowBackground(row.degraded ? Color.red.opacity(0.12) : Color.clear)
    }

    // MARK: - データ読み込み

    /// Phase G29 Task 1: `database` 直読みから `dataSource` 経由の呼び出しへ変更（挙動不変）。
    /// フォールバックの規律（要約は失敗時に前回値を保持・最終検査日時は失敗/未検査で nil・
    /// 一覧は失敗時に空配列）は変えていない ―― 各フィールドの fallback は元のまま個別に保持しつつ、
    /// Phase G29 Task 3 review fix (Critical 1) で「例外が起きたこと」自体は `loadErrorText` に
    /// 記録するようにした。以前は 3 つとも `try?` で握り潰しており、施錠リモート庫を
    /// `libraryToken` 無しで開くと `RemoteClientError.libraryLocked`（403）が消え、
    /// 「検査済み 0 件・破損 0 件」＋「破損している本はありません。」という**積極的な**
    /// 誤った安全宣言になっていた。
    private func reload() async {
        var encounteredError: Error?
        do {
            summary = try await dataSource.summary()
        } catch {
            encounteredError = error   // summary は前回値を保持（フォールバック不変）
        }
        do {
            lastScanAt = try await dataSource.lastScanAt()
        } catch {
            encounteredError = encounteredError ?? error
            lastScanAt = nil   // フォールバック不変
        }
        do {
            rows = IntegrityWindowLogic.sortedForDisplay(try await dataSource.list(status: .damaged))
        } catch {
            encounteredError = encounteredError ?? error
            rows = []   // フォールバック不変
        }
        loadErrorText = encounteredError.map {
            // fix round 4 (whole-branch review C1): 施錠メッセージに復帰手段（更新ボタン）を
            // 明示する。以前は「解錠してください」とだけ言い、解錠しても窓が自力で追従しなかった
            // ため、指示に従っても直らなかった。live-state 化（`RemoteIntegrityDataSource`）で
            // 次の `reload()` は新しいトークンを使うようになったが、それを呼ぶ手段（更新ボタン）が
            // あることも伝える。
            IntegrityWindowLogic.remoteFailureMessage(
                for: $0, context: "読み込みに失敗しました。")
        }
        // fix round 5 (Minor): 成功時だけ鮮度スタンプを進める。失敗時は「画面上のデータは
        // 直近の成功時点のまま」なので、スタンプもそのときのままにしておく。
        if encounteredError == nil {
            lastRefreshedAt = Date()
        }
    }

    /// fix round 4/5 (whole-branch review C1 / I2): 手動更新。
    ///
    /// - `refreshDataSource` があれば（＝リモート）まずデータ源そのものを取り替えを試みる。
    ///   `RemoteIntegrityDataSource.liveState`（弱参照）がブラウズ窓のクローズで死んでいた場合、
    ///   同じインスタンスをいくら読み直しても「確認できない」から抜け出せない ―― 取り替えて
    ///   初めて、再び開かれたブラウズ窓の新しい state（or 新しい `/me` 解決）を掴める
    ///   （fix round 4 では「更新してください」と案内するだけで、再解決の仕組みが無く
    ///   指示どおり押しても直らなかった。review 再指摘）。取り替えに失敗（`nil`）した場合は
    ///   今の `dataSource` のまま続行する（一時的な取得失敗の可能性があり、既存の状態を
    ///   失わせたくない）。
    /// - `canStartScan`/`scanUnavailableReason` の `@State` コピーを（新しい）`dataSource` から
    ///   同期的に読み直す。
    /// - 最後に `reload()`。
    private func refresh() {
        Task { @MainActor in
            if let refreshDataSource, let fresh = await refreshDataSource() {
                dataSource = fresh
            }
            canStartScan = dataSource.canStartScan
            scanUnavailableReason = dataSource.scanUnavailableReason
            await reload()
        }
    }

    // MARK: - ジョブの観測（Fix2/Fix4）

    /// ウィンドウが開いている間ずっと、`dataSource.jobProgress()` をポーリングして `jobStatus`
    /// へ反映する。CLI/MCP・他ウィンドウが開始したジョブも含めて「今このライブラリで何か
    /// 走っているか」を単一の真実源から取得する ―― これによりボタンの無効化・進捗表示は
    /// 開始者を問わず常に正しい（brief の「regardless of who started it」を満たす）。
    /// （Phase G29 Task 1: ポーリング先が registry 直読みから `dataSource` 越しに変わっただけで、
    /// ループの構造は変えていない。）
    ///
    /// Phase G29 Task 3 fix round 2 (Minor, Critical 1 の同族): `jobProgress()` は
    /// 取得失敗（権限不足・ネットワーク断等）で例外を投げるようになった（`IntegrityDataSource.swift`）。
    /// 失敗を「実行中でない」（nil）に化けさせず、`jobStatus` は直前の値を保持したまま
    /// `progressErrorText` を立てて理由を見せる。成功したら毎回クリアする。
    ///
    /// Phase G29 Task 3 fix round 4 (whole-branch review):
    /// - **Important 3**: 400ms は元々ローカルの in-process registry 呼び出し用の値で、
    ///   リモートの HTTP 往復には高すぎた（ジョブ非実行時でも 2.5 req/s、サーバ側は毎回
    ///   メインアクタへホップする）。`dataSource.idlePollIntervalNanoseconds` を使い、
    ///   実行中は高頻度、アイドル時はデータ源ごとの間隔（ローカルは同じ・リモートは大幅に長い）に
    ///   落とす。
    /// - **C1（tier の遅延反映）**: 毎 tick `canStartScan`/`scanUnavailableReason` の `@State`
    ///   コピーも読み直す。ネットワークを伴わない同期読み取りなので、間隔を落としても実害は
    ///   小さい。これにより「開いた時点では tier 未解決／未解錠だった」窓も、ブラウズ窓側の
    ///   解錠・`/me` 完了を数秒以内に追いかける。
    /// - **Minor（`scanErrorText` の自動クリア）**: ジョブが実際に実行中だと判明したら
    ///   `scanErrorText` をクリアする。202 の応答だけ失われて実際は起動していた場合、
    ///   進捗バーの隣に「開始できませんでした」が残り続けるのを防ぐ。
    private static let activePollIntervalNanoseconds: UInt64 = 400_000_000

    private func startObserving() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            var wasRunning = false
            while !Task.isCancelled {
                do {
                    let status = try await dataSource.jobProgress()
                    jobStatus = status
                    progressErrorText = nil
                    // fix round 5 (Minor, review 再指摘): 「実行中のジョブがある」だけで clear
                    // すると、無関係な他ジョブ（例: 表紙圧縮）が同じライブラリで走っているだけで
                    // 本物の 403「スキャンを開始できませんでした。」まで消えてしまう。
                    // 自分が起動しようとした full-scan だと確認できたときだけ clear する
                    // （＝ユーザー自身のアクションの結果として消す。他人のジョブでは消さない）。
                    if status?.isIntegrityFullScan == true {
                        scanErrorText = nil
                    }
                    if wasRunning, status == nil {
                        // ジョブが終わった。自分で開始していれば box に詳細レポートが入っている。
                        if let report = dataSource.takeCompletionReport() {
                            lastReport = report
                        }
                        await reload()
                    }
                    wasRunning = status != nil
                } catch {
                    // `jobStatus`/`wasRunning` は前回値のまま ―― 「取得できていない」を
                    // 「止まった」と混同しない。
                    progressErrorText = IntegrityWindowLogic.remoteFailureMessage(
                        for: error, context: "進捗を取得できません。")
                }
                // fix round 4 (C1): tier は live-state 経由で変わりうるので、jobProgress の成否に
                // かかわらず毎 tick 読み直す。
                canStartScan = dataSource.canStartScan
                scanUnavailableReason = dataSource.scanUnavailableReason
                if Task.isCancelled { return }
                let interval = wasRunning ? Self.activePollIntervalNanoseconds : dataSource.idlePollIntervalNanoseconds
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    // MARK: - スキャン開始/確認

    /// 「全件やり直し」だけは spec 上 31 時間規模になりうるため、開始前に確認する。
    /// **ここも `.sheet`/`.confirmationDialog` は使わない** — `NSAlert().runModal()` は window に
    /// 添付されない app-modal であり、`BookDeleteCommand`/`RelinkSheet` の確認と同じ形。
    private func requestScan(_ action: IntegrityWindowLogic.ScanAction) {
        if action.needsConfirmation {
            let alert = NSAlert()
            alert.messageText = "全件やり直しを開始しますか？"
            alert.informativeText = "対象冊数によっては非常に長時間（数時間〜数十時間）かかることがあります。開始後はいつでも中断できます。"
            alert.addButton(withTitle: "開始")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        startScan(action)
    }

    /// G27b 最終レビュー Fix2: `IntegrityScanTask` を自前で回すのではなく、CLI/MCP の
    /// `POST .../integrity/full-scan` と同じ registry を通す `dataSource.startScan(mode:)` を呼ぶ
    /// （Phase G29 Task 1: registry 呼び出し自体は `LocalIntegrityDataSource` に移設。ここでは
    /// 「開始後すぐ jobStatus を反映する」までの手順を変えていない）。
    ///
    /// Phase G29 Task 3 fix round 2 (Critical, review 再指摘・Critical 1 の同族):
    /// `dataSource.startScan(mode:)` は busy（409）を `false` として返すのが正常系だが、
    /// それ以外の失敗（403 施錠・権限不足等）は例外として投げる。従来の `try?` は両方を
    /// 一様に「何も起きない」に潰していた ―― busy はそのまま静かに次のポーリングへ委ねるが、
    /// それ以外は `scanErrorText` を立てて理由を見せる。
    private func startScan(_ action: IntegrityWindowLogic.ScanAction) {
        lastReport = nil
        scanErrorText = nil
        Task { @MainActor in
            do {
                let started = try await dataSource.startScan(mode: action.mode)
                if started {
                    // 次のポーリング tick を待たず、起動直後から running を即時反映する。
                    // ここでの取得失敗は無視してよい（`try?`）―― 400ms 後の `startObserving()`
                    // のポーリングが同じ失敗を検出し `progressErrorText` を立てる。
                    jobStatus = try? await dataSource.jobProgress()
                }
                // started == false（busy）のときは何もしない。次のポーリングで jobStatus が反映される。
            } catch {
                scanErrorText = IntegrityWindowLogic.remoteFailureMessage(
                    for: error, context: "スキャンを開始できませんでした。")
            }
        }
    }

    /// Phase G29 Task 3 fix round 3 (Minor, review 再々指摘): `dataSource.cancel()` の失敗を
    /// `startScan` と同じ扱いにする ―― 進捗取得が失敗して `isScanning` が凍結表示のまま残っている
    /// 状況では「中断」がまさにユーザーが押したくなるボタンで、黙って何もしないままにはできない。
    /// 同じ `scanErrorText` を使う（開始・中断はどちらも「スキャン操作」の失敗として同列に扱う）。
    private func cancelScan() {
        Task { @MainActor in
            do {
                try await dataSource.cancel()
                scanErrorText = nil
            } catch {
                scanErrorText = IntegrityWindowLogic.remoteFailureMessage(
                    for: error, context: "中断できませんでした。")
            }
        }
    }

    // MARK: - 行操作

    private func revealInFinder(_ row: IntegrityRow) {
        guard let path = row.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func relink(_ row: IntegrityRow) {
        // Phase G29 Task 3: リモートでは `database` が nil（行メニュー側で既に無効化済み。
        // ここは到達しない経路への保険）。
        guard let database else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "「\(row.title)」にリンクするファイルを選択してください。")
        if let path = row.path {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookID = Int(row.id)
        do {
            try database.relinkBook(id: bookID, newPath: url.path(percentEncoded: false))
            Task { @MainActor in await reload() }
            if let appState {
                Task { await appState.refreshCoverAndPageCount(afterRelinkOf: bookID, refreshUI: true) }
            }
        } catch {
            let a = NSAlert()
            a.messageText = String(localized: "再リンクに失敗しました")
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    private func delete(_ row: IntegrityRow) {
        // Phase G29 Task 3: リモートでは `database`/`bundleURL` が nil（行メニュー側で既に
        // 無効化済み。ここは到達しない経路への保険）。
        guard let database, let bundleURL else { return }
        BookDeleteCommand.deleteFromLibrary(
            bookIDs: [Int(row.id)],
            database: database,
            bundleURL: bundleURL,
            appState: appState,
            undoManager: appState?.undoManager,
            confirm: true
        )
        Task { @MainActor in await reload() }
    }
}
