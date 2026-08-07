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

    /// 概要行（brief: 「最終検査 / 未検査 N 冊 / 破損 N 冊 / 劣化 N 冊」）。
    static func summaryLine(summary: IntegritySummary, lastScanAt: Date?, now: Date = Date()) -> String {
        let last = lastScanAt.map(formattedDate) ?? "未検査"
        return "最終検査: \(last)　未検査 \(summary.unchecked) 冊　破損 \(summary.damaged) 冊　劣化 \(summary.degraded) 冊"
    }

    static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateStyle = .medium
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
                    dataSource: dataSource)
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
        // review Critical 1: まず、同じ庫を既に開いているブラウズウィンドウの `RemoteLibraryState`
        // を探す。見つかれば `libraryToken`（施錠庫の解錠済みトークン）と `tier` を解決し直さず
        // そのまま使う ―― `/me` の追加往復も不要になる。メニュー項目は `\.remoteState` が非 nil
        // のときしか開けない（`StackNestApp.swift`）ため、開いた瞬間は必ずこの state が生きている。
        if let liveState = RemoteLibraryRegistry.shared.allObjects.first(where: {
            $0.serverID == serverID && $0.libraryUUID == libraryUUID
        }) {
            dataSource = RemoteIntegrityDataSource(
                client: liveState.client, libraryUUID: libraryUUID,
                libraryToken: liveState.libraryToken, tier: liveState.tier)
            return
        }
        // フォールバック: `RemoteLibraryWindowContainer.resolve()` と同じ `ServerConnectionStore`
        // パターン（ブラウズウィンドウが無い状態で integrity ウィンドウだけが復元された場合等）。
        // `libraryToken` を持てないため、施錠庫では `summary`/`list` が 403(libraryLocked) になりうる
        // ―― `IntegrityCheckView.reload()` 側でエラー表示する。
        guard let conn = store.connection(id: serverID),
              let base = URL(string: conn.baseURL) else {
            notFound = true
            return
        }
        let client = RemoteLibraryClient(baseURL: base, deviceToken: conn.token)
        // `/me` はデバイストークンの tier（grant 由来）を返す。ライブラリの施錠状態とは無関係
        // （施錠は `libraryToken` 側の話）なので、`libraryToken: nil` のままで解決できる。
        // 呼び出し自体が失敗した場合（オフライン等）は `tierResolutionFailed` を立てて渡す ――
        // 「権限が無い」と「権限を確認できない」は原因が違うため、ビューに出す理由文言を分ける
        // （review Minor 4）。
        let meResult = try? await client.me(libraryToken: nil)
        dataSource = RemoteIntegrityDataSource(
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
    /// Phase G29 Task 1: 破損チェックウィンドウのデータ源。ローカル庫は `LocalIntegrityDataSource`
    /// （DB と registry を直接触る、挙動不変の移設）。relink/delete/Finder 表示は引き続き
    /// `database`/`bundleURL` を直接使う（このプロトコルのスコープ外）。
    let dataSource: IntegrityDataSource

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
    /// ありません。」という積極的な安全宣言を出さない ―― 読めなかったことと破損が無いことは
    /// 区別しなければならない。
    @State private var loadErrorText: String?

    private var isScanning: Bool { jobStatus != nil }
    private var progress: (done: Int, total: Int) { (jobStatus?.done ?? 0, jobStatus?.total ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("整合性チェック")
                .font(.title2.bold())
            Text(IntegrityWindowLogic.summaryLine(summary: summary, lastScanAt: lastScanAt))
                .foregroundStyle(.secondary)

            HStack {
                ForEach(IntegrityWindowLogic.ScanAction.allCases) { action in
                    Button(action.title) { requestScan(action) }
                        // review Critical 2: tier ゲートを消費する。`.disabled(isScanning)` だけでは
                        // read/edit 接続でもボタンが有効なままで、押すと 403 が `startScan` の
                        // `try?` に握り潰され「何も起きない」になっていた（spec §3.4・受け入れ基準 3）。
                        // 判定そのものは `IntegrityWindowLogic.scanButtonDisabled` に切り出してあり
                        // （テスト可能にするため）、ここはそれを呼ぶだけに保つ。
                        .disabled(IntegrityWindowLogic.scanButtonDisabled(
                            isScanning: isScanning, canStartScan: dataSource.canStartScan))
                }
                Spacer()
                if isScanning {
                    Button("中断") { cancelScan() }
                }
            }
            // review Critical 2: `.help()`（ホバーしないと見えない）ではなく、常に見える形で理由を
            // 出す。tier が足りる（`scanUnavailableReason == nil`）間は何も出さない。
            if let reason = dataSource.scanUnavailableReason {
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

            if isScanning {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                if jobStatus?.isIntegrityFullScan == true {
                    Text("検査中… \(progress.done)/\(progress.total)")
                        .font(.caption)
                        .monospacedDigit()
                } else {
                    // 同じライブラリで他のメンテナンスジョブ（表紙圧縮・メタ補完等）が実行中。
                    // registry は庫あたり同時 1 本しか許さないため、ここのボタンも busy として
                    // 無効化する（誤って別ジョブの done/total を「検査」として誤読させない）。
                    Text("他のメンテナンス処理を実行中です（\(jobStatus?.job ?? "")）… \(progress.done)/\(progress.total)")
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
        loadErrorText = encounteredError.map(Self.loadErrorMessage(for:))
    }

    /// review Critical 1: `RemoteClientError.libraryLocked` は「施錠されていて未解錠」という
    /// 一級市民のケース（`RemoteClientError.swift:19-23` のコメント参照）なので専用の文言を出す。
    /// それ以外は汎用の失敗文言（読み込み失敗の原因はネットワーク断・タイムアウト等さまざまで、
    /// ここで種類ごとに出し分ける必要はない ―― 「読めなかった」ことが伝われば十分）。
    private static func loadErrorMessage(for error: Error) -> String {
        if case RemoteClientError.libraryLocked = error {
            return "この庫は施錠されています。庫のウィンドウで解錠してください。"
        }
        return "読み込みに失敗しました。"
    }

    // MARK: - ジョブの観測（Fix2/Fix4）

    /// ウィンドウが開いている間ずっと、`dataSource.jobProgress()` をポーリングして `jobStatus`
    /// へ反映する。CLI/MCP・他ウィンドウが開始したジョブも含めて「今このライブラリで何か
    /// 走っているか」を単一の真実源から取得する ―― これによりボタンの無効化・進捗表示は
    /// 開始者を問わず常に正しい（brief の「regardless of who started it」を満たす）。400ms
    /// 間隔は 31 時間規模の走査に対して十分高頻度かつ、SSE を張らない設計方針
    /// （`MaintenanceJobRegistry` のコメント参照）とも整合する（Phase G29 Task 1: ポーリング先が
    /// registry 直読みから `dataSource` 越しに変わっただけで、ループの構造・間隔は変えていない）。
    private func startObserving() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            var wasRunning = false
            while !Task.isCancelled {
                let status = await dataSource.jobProgress()
                jobStatus = status
                if wasRunning, status == nil {
                    // ジョブが終わった。自分で開始していれば box に詳細レポートが入っている。
                    if let report = dataSource.takeCompletionReport() {
                        lastReport = report
                    }
                    await reload()
                }
                wasRunning = status != nil
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
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
    private func startScan(_ action: IntegrityWindowLogic.ScanAction) {
        lastReport = nil
        Task { @MainActor in
            let started = (try? await dataSource.startScan(mode: action.mode)) ?? false
            if started {
                // 次のポーリング tick を待たず、起動直後から running を即時反映する。
                jobStatus = await dataSource.jobProgress()
            }
            // started == false（busy）のときは何もしない。次のポーリングで jobStatus が反映される。
        }
    }

    private func cancelScan() {
        Task { await dataSource.cancel() }
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
