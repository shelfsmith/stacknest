// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import Foundation
import LibraryServer
import LibraryStore
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
    static func sortedForDisplay(
        _ rows: [(book: BookRow, record: IntegrityRecord)]
    ) -> [(book: BookRow, record: IntegrityRecord)] {
        rows.sorted { a, b in
            if a.record.isDegraded != b.record.isDegraded { return a.record.isDegraded }
            if a.record.isDegraded { return a.record.checkedAt > b.record.checkedAt }
            return a.book.title.localizedStandardCompare(b.book.title) == .orderedAscending
        }
    }
}

// MARK: - IntegrityFullScanJob

/// Phase G27b Task 6 / 最終レビュー Fix2: 整合性チェックウィンドウの「full-scan」ジョブ名。
/// CLI/MCP の HTTP ルート（`POST .../integrity/full-scan`）が `maintenanceRegistry.start` に
/// 渡す job 名（`Sources/LibraryServer/LibraryServerCore.swift`）と**文字列として完全一致**させる
/// こと。ここがずれると、GUI が開始したジョブを CLI の `GET maintenance/status` が別ジョブとして
/// 見てしまい（あるいはその逆）、"同じ registry を使っているのに busy 判定が食い違う" という
/// 一番検出しづらい形で Fix2 の意図が壊れる。
private let integrityFullScanJobName = "full-scan"

/// `MaintenanceJobRegistry.start` の `run` クロージャは `@Sendable` で戻り値は `Int`
/// （完了件数）のみ。詳細な `FullScanReport`（byStatus 内訳・cancelled・volumeUnavailableSkips）を
/// UI へ持ち帰るためのスレッド安全な受け渡し箱。**自分（このウィンドウ）がこのタブで開始した
/// スキャンにのみ**使う ―― CLI/MCP など他所が開始したジョブにはこの箱が無いため、
/// その完了は `lastReport` の詳細表示なしに `reload()` のみで反映する（brief の要求である
/// 「進捗表示・ボタン無効化」は満たすが、完了時の内訳キャプションは自分が開始した場合のみ）。
private final class IntegrityReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report: FullScanReport?
    func set(_ r: FullScanReport) { lock.lock(); report = r; lock.unlock() }
    func take() -> FullScanReport? { lock.lock(); defer { lock.unlock() }; return report }
}

// MARK: - IntegrityCheckRef / WindowGroup container

/// 整合性チェックウィンドウを開くための値型（`WindowGroup(for:)` のキー）。
/// ローカル庫専用のためサーバ/トークンは持たず、庫を一意に識別する `bundleURL` だけを持つ
/// （`RemoteLibraryRef` が `serverID`/`libraryUUID` を持つのと同じ役割）。
struct IntegrityCheckRef: Codable, Hashable {
    let bundleURL: URL
}

/// `IntegrityCheckRef` を解決し、対応する庫が（このプロセス内で）開いていれば
/// `IntegrityCheckView` を表示するコンテナ。`RemoteLibraryWindowContainer` と同じ
/// 「参照値から state を解決するコンテナ」パターンを踏襲する。
///
/// GUI はローカル DB を直接読む（brief: `IntegrityItemDTO` は `path` を持たないため、
/// Finder 表示に必要な実パスは HTTP DTO からは得られない）。そのためリモートクライアント経由の
/// 解決ではなく、同一プロセス内で既に開いている `AppState`（`AppState.activeInstances`）から
/// `bundleURL` が一致するものを探す。メニュー項目自体がローカル庫のフォーカス時にしか有効化
/// されないため（`FileCommands` の `canManageLocalFiles` ゲート）、通常はここで必ず見つかる。
struct IntegrityWindowContainer: View {
    let ref: IntegrityCheckRef
    @State private var appState: AppState?
    @State private var notFound = false

    var body: some View {
        Group {
            if let appState, let database = appState.database {
                IntegrityCheckView(bundleURL: ref.bundleURL, database: database, appState: appState)
            } else if notFound {
                missingView
            } else {
                ProgressView()
                    .frame(minWidth: 400, minHeight: 300)
            }
        }
        .onAppear { resolve() }
    }

    private var missingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("ライブラリが開かれていません")
                .font(.headline)
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }

    private func resolve() {
        guard appState == nil, notFound == false else { return }
        if let match = AppState.activeInstances.allObjects.first(where: { $0.bundleURL.path == ref.bundleURL.path }) {
            appState = match
        } else {
            notFound = true
        }
    }
}

// MARK: - IntegrityCheckView

/// 整合性チェックウィンドウの本体。開いた時点では**スキャンを走らせず**、保存済みの結果
/// （`Database.integritySummary()` / `integrityRecords(status:)`）を即表示する。
struct IntegrityCheckView: View {
    let bundleURL: URL
    let database: Database
    var appState: AppState?

    @State private var summary = IntegritySummary(checked: 0, unchecked: 0, damaged: 0, degraded: 0)
    @State private var lastScanAt: Date?
    @State private var rows: [(book: BookRow, record: IntegrityRecord)] = []
    // G27b 最終レビュー Fix2/Fix4: ウィンドウは `MaintenanceJobRegistry` の状態を**観測**するだけで、
    // 自前のタスク/フラグを所有しない。`jobStatus` は「今このライブラリで走っているジョブ」を
    // ポーリングで反映したもので、GUI が開始したかどうかを問わない（CLI/MCP・他ウィンドウが
    // 開始したジョブも同じフィールドに映る）。これにより:
    //   - ウィンドウを閉じてもジョブは registry 側で走り続ける（scanTask を持たないので
    //     「唯一の参照を失って中断できなくなる」が構造的に起こらない＝Fix4）。
    //   - 再度開けば `.onAppear` の最初のポーリングで即座に isScanning=true に復帰する。
    @State private var jobStatus: MaintenanceJobRegistry.JobStatus?
    @State private var lastReport: FullScanReport?
    @State private var pollTask: Task<Void, Never>?
    /// 自分（このウィンドウ）が開始したスキャンの詳細レポート受け皿。他所が開始したジョブには
    /// 対応する箱が無いため `lastReport` は `reload()` 相当の反映のみになる（型コメント参照）。
    @State private var pendingReportBox: IntegrityReportBox?

    private var isScanning: Bool { jobStatus != nil }
    private var progress: (done: Int, total: Int) { (jobStatus?.done ?? 0, jobStatus?.total ?? 0) }
    /// `AllOpenLibrariesDataSource`/`AppStateLibraryDataSource` と同じ `ensureLibraryUUID()` を使う
    /// ―― registry のキー（library uuid 文字列）を HTTP ルートと完全に一致させるため。
    private var libraryUUID: String? { appState?.librarySettings?.ensureLibraryUUID() }

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
                if jobStatus?.job == integrityFullScanJobName {
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
                List(rows, id: \.book.id) { entry in
                    rowView(entry)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 560)
        .onAppear {
            reload()
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
    private func rowView(_ entry: (book: BookRow, record: IntegrityRecord)) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if entry.record.isDegraded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("劣化: 前回は正常だった本が壊れています（ビット腐敗の疑い）")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.book.title)
                    .fontWeight(entry.record.isDegraded ? .semibold : .regular)
                Text(entry.book.path ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !entry.record.badEntries.isEmpty {
                    Text(entry.record.badEntries.prefix(3).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            Spacer()
            if entry.record.isDegraded {
                Text("劣化")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
            }
            Menu {
                Button("Finder で表示") { revealInFinder(entry.book) }
                    .disabled(entry.book.path == nil)
                Button("再リンク…") { relink(entry.book) }
                Button("ライブラリから削除", role: .destructive) { delete(entry.book) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.vertical, 4)
        .listRowBackground(entry.record.isDegraded ? Color.red.opacity(0.12) : Color.clear)
    }

    // MARK: - データ読み込み

    private func reload() {
        summary = (try? database.integritySummary()) ?? summary
        if let unix = try? database.integrityLastCheckedAt() {
            lastScanAt = Date(timeIntervalSince1970: TimeInterval(unix))
        } else {
            lastScanAt = nil
        }
        let fetched = (try? database.integrityRecords(status: .damaged)) ?? []
        rows = IntegrityWindowLogic.sortedForDisplay(fetched.map { (book: $0.0, record: $0.1) })
    }

    // MARK: - ジョブの観測（Fix2/Fix4）

    /// ウィンドウが開いている間ずっと、このライブラリの `MaintenanceJobRegistry.status(library:)`
    /// をポーリングして `jobStatus` へ反映する。CLI/MCP・他ウィンドウが開始したジョブも含めて
    /// 「今このライブラリで何か走っているか」を単一の真実源から取得する ―― これにより
    /// ボタンの無効化・進捗表示は開始者を問わず常に正しい（brief の「regardless of who
    /// started it」を満たす）。400ms 間隔は 31 時間規模の走査に対して十分高頻度かつ、
    /// SSE を張らない設計方針（`MaintenanceJobRegistry` のコメント参照）とも整合する。
    private func startObserving() {
        pollTask?.cancel()
        guard let uuid = libraryUUID else { return }
        pollTask = Task { @MainActor in
            var wasRunning = false
            while !Task.isCancelled {
                let status = await LocalControlController.shared.maintenanceRegistry.status(library: uuid)
                jobStatus = status
                if wasRunning, status == nil {
                    // ジョブが終わった。自分で開始していれば box に詳細レポートが入っている。
                    if let box = pendingReportBox, let report = box.take() {
                        lastReport = report
                    }
                    pendingReportBox = nil
                    reload()
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
    /// `POST .../integrity/full-scan` と同じ `LocalControlController.shared.maintenanceRegistry`
    /// を通す（同じ job 名 `integrityFullScanJobName` で登録する）。`start` が false（他ジョブが
    /// 同一庫で実行中）を返すことは通常ここに来る前にボタンが無効化されているため稀だが、
    /// レースで到達しても registry が実際の多重起動を防いでくれる（自前ガードを重複させない）。
    private func startScan(_ action: IntegrityWindowLogic.ScanAction) {
        guard let uuid = libraryUUID else { return }
        lastReport = nil
        let box = IntegrityReportBox()
        pendingReportBox = box
        // `self`（View struct・非 Sendable）を後段の `@Sendable` クロージャへ取り込まないよう、
        // 必要な値だけを事前にローカル定数へ写す（`database`/`bundleURL` は Sendable な値、
        // `action` はクロージャの外側でキャプチャされるローカル引数なのでそのままでよい）。
        let db = database
        let libraryBundleURL = bundleURL
        Task { @MainActor in
            let started = await LocalControlController.shared.maintenanceRegistry.start(
                library: uuid, job: integrityFullScanJobName
            ) { progress, isCancelled in
                try await withoutActuallyEscaping(isCancelled) { escapableIsCancelled in
                    let report = try await FullIntegrityScanner.scan(
                        database: db, mode: action.mode,
                        deps: FullIntegrityScanner.liveDependencies(libraryBundleURL: libraryBundleURL),
                        progress: { d, t in progress(d, t) },
                        isCancelled: escapableIsCancelled)
                    box.set(report)
                    return report.scanned
                }
            }
            if !started {
                // busy（他ジョブが同一庫で実行中）。次のポーリングで jobStatus が反映される。
                pendingReportBox = nil
            } else {
                // 次のポーリング tick を待たず、起動直後から running を即時反映する。
                jobStatus = await LocalControlController.shared.maintenanceRegistry.status(library: uuid)
            }
        }
    }

    private func cancelScan() {
        guard let uuid = libraryUUID else { return }
        Task { await LocalControlController.shared.maintenanceRegistry.cancel(library: uuid) }
    }

    // MARK: - 行操作

    private func revealInFinder(_ book: BookRow) {
        guard let path = book.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func relink(_ book: BookRow) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "「\(book.title)」にリンクするファイルを選択してください。")
        if let path = book.path {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try database.relinkBook(id: book.id, newPath: url.path(percentEncoded: false))
            reload()
            if let appState {
                Task { await appState.refreshCoverAndPageCount(afterRelinkOf: book.id, refreshUI: true) }
            }
        } catch {
            let a = NSAlert()
            a.messageText = String(localized: "再リンクに失敗しました")
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    private func delete(_ book: BookRow) {
        BookDeleteCommand.deleteFromLibrary(
            bookIDs: [book.id],
            database: database,
            bundleURL: bundleURL,
            appState: appState,
            undoManager: appState?.undoManager,
            confirm: true
        )
        reload()
    }
}
