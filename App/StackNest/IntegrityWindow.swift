// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import Foundation
import LibraryStore
import OSLog
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

// MARK: - IntegrityScanTask

/// スレッド安全なキャンセルフラグ（`CoverRegenerationTask.CoverRegenerationCancelFlag` と同じ設計）。
/// `FullIntegrityScanner.scan` の `isCancelled` は `@Sendable () async -> Bool` で MainActor 外から
/// 呼ばれうるため、単純な MainActor プロパティのキャプチャではなくロック付きフラグを使う。
private final class IntegrityScanCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Phase G27b Task 6: 整合性チェックウィンドウ用の詳細スキャンタスク。
///
/// `DuplicateScanTask` / `CoverRegenerationTask` と同じ shape（database を保持し、cancel 可能、
/// `onProgress` で進捗を通知する）を踏襲する。実体は CLI/MCP/HTTP と共有するコア
/// `AppCore.FullIntegrityScanner` にそのまま委譲する（GUI 独自のスキャンロジックは持たない）。
@MainActor
final class IntegrityScanTask {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "IntegrityScan")
    private let database: Database
    private let mode: FullScanMode
    private let cancelFlag = IntegrityScanCancelFlag()

    init(database: Database, mode: FullScanMode) {
        self.database = database
        self.mode = mode
    }

    func cancel() { cancelFlag.cancel() }

    func run(onProgress: @escaping @Sendable @MainActor (Int, Int) -> Void) async -> FullScanReport {
        do {
            return try await FullIntegrityScanner.scan(
                database: database,
                mode: mode,
                deps: FullIntegrityScanner.liveDependencies(),
                progress: { @Sendable done, total in
                    Task { @MainActor in onProgress(done, total) }
                },
                isCancelled: { [cancelFlag] in cancelFlag.isCancelled }
            )
        } catch {
            Self.logger.error("IntegrityScanTask failed: \(error.localizedDescription, privacy: .public)")
            return FullScanReport(scanned: 0, byStatus: [:], persistenceFailures: 0, cancelled: cancelFlag.isCancelled)
        }
    }
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
    @State private var scanTask: IntegrityScanTask?
    @State private var isScanning = false
    @State private var progress: (done: Int, total: Int) = (0, 0)
    @State private var lastReport: FullScanReport?

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
                    Button("中断") { scanTask?.cancel() }
                }
            }

            if isScanning {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                Text("検査中… \(progress.done)/\(progress.total)")
                    .font(.caption)
                    .monospacedDigit()
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
        .onAppear { reload() }
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

    private func startScan(_ action: IntegrityWindowLogic.ScanAction) {
        let task = IntegrityScanTask(database: database, mode: action.mode)
        scanTask = task
        isScanning = true
        progress = (0, 0)
        lastReport = nil
        Task { @MainActor in
            let report = await task.run { done, total in
                progress = (done, total)
            }
            isScanning = false
            scanTask = nil
            lastReport = report
            reload()
        }
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
