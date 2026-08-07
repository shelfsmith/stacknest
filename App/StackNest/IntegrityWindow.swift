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
/// - `.remote`: `RemoteLibraryWindowContainer.resolve()` と**同じ解決パターン**
///   （`ServerConnectionStore` から接続情報を引き、新しい `RemoteLibraryClient` を作る）を使う。
///   新しい解決の仕組みは作らない。tier は `/me` で解決し、解決できなければ fail-closed で
///   `.read`（＝スキャン開始不可・閲覧のみ）に倒す。
struct IntegrityWindowContainer: View {
    let ref: IntegrityCheckRef
    @State private var localAppState: AppState?
    @State private var localDatabase: Database?
    @State private var localBundleURL: URL?
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
            if let dataSource {
                IntegrityCheckView(
                    bundleURL: localBundleURL, database: localDatabase, appState: localAppState,
                    dataSource: dataSource)
            } else if notFound {
                missingView
            } else {
                ProgressView()
                    .frame(minWidth: 400, minHeight: 300)
            }
        }
        // ローカルは同期解決だが、リモートは `/me` の HTTP 呼び出しを伴うため `resolve()` 全体を
        // async にしてある（`RemoteLibraryWindowContainer` と同じ `.task { await resolve() }`）。
        .task { await resolve() }
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
            localBundleURL = bundleURL
            // `AppState.finishOpening()` は `database`/`librarySettings` を同期的に設定してから
            // `activeInstances` へ登録する（`AppState.swift` 参照）ため、`activeInstances` から
            // 見つかった時点で `match.database` は必ず non-nil。
            if let database = match.database {
                localDatabase = database
                dataSource = LocalIntegrityDataSource(database: database, bundleURL: bundleURL, appState: match)
            }
        } else {
            notFound = true
        }
    }

    @MainActor
    private func resolveRemote(serverID: UUID, libraryUUID: String) async {
        // `RemoteLibraryWindowContainer.resolve()` と同じ解決パターン: `ServerConnectionStore` から
        // 接続情報（baseURL・デバイストークン）を引き、新しい `RemoteLibraryClient` を作る。
        // 既に開いている庫ブラウズウィンドウの `RemoteLibraryState` を探しに行く仕組みは
        // 別パターンになってしまうため使わない（「新しい解決の仕組みを作らない」の遵守）。
        guard let conn = ServerConnectionStore().connection(id: serverID),
              let base = URL(string: conn.baseURL) else {
            notFound = true
            return
        }
        let client = RemoteLibraryClient(baseURL: base, deviceToken: conn.token)
        // `/me` はデバイストークンの tier（grant 由来）を返す。ライブラリの施錠状態とは無関係
        // （施錠は `libraryToken` 側の話）なので、`libraryToken: nil` のままで解決できる。
        // 失敗時は fail-closed で `.read`（閲覧のみ・スキャン開始不可）に倒す。
        let tier = (try? await client.me(libraryToken: nil))?.tier ?? .read
        dataSource = RemoteIntegrityDataSource(client: client, libraryUUID: libraryUUID, libraryToken: nil, tier: tier)
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
                        .disabled(isScanning)
                }
                Spacer()
                if isScanning {
                    Button("中断") { cancelScan() }
                }
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

            if rows.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("破損している本はありません。")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
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
                Text(row.path ?? "—")
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
    /// 一覧は失敗時に空配列）は変えていない。
    private func reload() async {
        summary = (try? await dataSource.summary()) ?? summary
        if let value = try? await dataSource.lastScanAt() {
            lastScanAt = value
        } else {
            lastScanAt = nil
        }
        let fetched = (try? await dataSource.list(status: .damaged)) ?? []
        rows = IntegrityWindowLogic.sortedForDisplay(fetched)
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
