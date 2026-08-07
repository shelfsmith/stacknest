// SPDX-License-Identifier: MIT
import AppCore
import Foundation
import LibraryServer
import LibraryStore

// Phase G29 Task 1: 破損チェックウィンドウのデータ源を抽象化する（挙動不変のリファクタリング）。
//
// このファイルは機能追加ではない。`IntegrityWindow.swift` が DB と
// `MaintenanceJobRegistry` を直接触っていた部分を、プロトコル越しに置き換えるための
// 型を定義する。ローカル実装（`LocalIntegrityDataSource`）は既存ロジックの移設であり、
// リモート実装は Phase G29 Task 3 が追加する。

/// 破損チェックウィンドウ 1 行分の表示モデル。
///
/// `path` は **ローカル庫でのみ入る**。リモートでは HTTP DTO がパスを運ばないので nil になる
/// （理由は spec §2.4: コードベース全体の規約として HTTP はパスを返さないうえ、
/// パスはサーバ機のファイルシステム上のものでリモート機の Finder で開いても意味がない）。
/// **ビューは `path == nil` で「Finder で表示」を出し分ける**ので、
/// ビュー側が「リモートかどうか」を知る必要はない。
struct IntegrityRow: Identifiable, Sendable {
    let id: Int64
    let title: String
    /// 表示用のファイル名（basename）。ローカル・リモートとも入る。
    let filename: String?
    /// 実パス。ローカルのみ。
    let path: String?
    let status: IntegrityStatus
    let checkedAt: Date?
    let entryCount: Int?
    let badEntries: [String]
    let degraded: Bool
}

/// ジョブの実行状況（ローカル registry / リモート HTTP を同じ形にそろえたもの）。
///
/// `job` は `MaintenanceJobRegistry.JobStatus.job` と同じ役割 ―― ウィンドウが
/// 「今走っているのは自分（破損チェック）のジョブか、それとも同じライブラリで動いている
/// 別のメンテナンスジョブ（表紙圧縮・メタ補完等）か」を区別してキャプションを出し分けるために使う
/// （`IntegrityWindow.swift` の `jobStatus?.job == integrityFullScanJobName` 分岐、挙動不変で移設）。
struct IntegrityJobProgress: Equatable, Sendable {
    let job: String
    let done: Int
    let total: Int

    /// Phase G29 Task 1 review fixup: `integrityFullScanJobName` を `private` に戻すため、
    /// 文字列比較そのものをこの型（＝定数と同じファイル）に閉じ込める。ビュー側は生の文字列定数に
    /// 触れず、この bool だけを見る。
    var isIntegrityFullScan: Bool { job == integrityFullScanJobName }
}

/// 破損チェックウィンドウのデータ源。
///
/// ローカル庫は DB と `MaintenanceJobRegistry` を直接、リモート庫は HTTP 越しに
/// 同じ操作を提供する。**ウィンドウはこのプロトコルしか触らない**（relink/delete/Finder 表示は
/// ローカル専用の操作としてスコープ外 ―― ウィンドウが `database`/`bundleURL` を直接使う）。
@MainActor
protocol IntegrityDataSource {
    /// 件数の要約。
    func summary() async throws -> IntegritySummary
    /// 最後にスキャンした時刻。取得できなければ nil。
    func lastScanAt() async throws -> Date?
    /// 指定状態の一覧。
    func list(status: IntegrityStatus) async throws -> [IntegrityRow]
    /// スキャン開始。`false` は「他ジョブ実行中」（HTTP では 409）。
    func startScan(mode: FullScanMode) async throws -> Bool
    /// 実行中ジョブの中断。
    func cancel() async
    /// 実行中でなければ nil。
    func jobProgress() async -> IntegrityJobProgress?
    /// スキャンを開始できるか。リモートで admin 未満なら false。
    var canStartScan: Bool { get }
    /// `canStartScan` が false のときに表示する理由。true のときは nil。
    var scanUnavailableReason: String? { get }
    /// スキャン完了直後、**自分（このデータ源インスタンス）が開始したジョブ**の詳細レポートを
    /// 1 回だけ取り出す。他所（CLI/MCP・別ウィンドウ）が開始したジョブや、詳細レポートの概念が
    /// ない場合（リモート）は常に nil ―― `IntegrityReportBox` の仕組み（挙動不変で移設）。
    func takeCompletionReport() -> FullScanReport?
}

/// `MaintenanceJobRegistry.start` の `run` クロージャは `@Sendable` で戻り値は `Int`
/// （完了件数）のみ。詳細な `FullScanReport`（byStatus 内訳・cancelled・volumeUnavailableSkips）を
/// UI へ持ち帰るためのスレッド安全な受け渡し箱。**自分（このウィンドウ）がこのタブで開始した
/// スキャンにのみ**使う ―― CLI/MCP など他所が開始したジョブにはこの箱が無いため、
/// その完了は `lastReport` の詳細表示なしに `reload()` のみで反映する
/// （`IntegrityWindow.swift` から挙動不変で移設）。
private final class IntegrityReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report: FullScanReport?
    func set(_ r: FullScanReport) { lock.lock(); report = r; lock.unlock() }
    func take() -> FullScanReport? { lock.lock(); defer { lock.unlock() }; return report }
}

/// ローカル庫の `IntegrityDataSource` 実装。DB を直接読み、
/// `LocalControlController.shared.maintenanceRegistry` を通してジョブを起動/観測する。
/// **`IntegrityWindow.swift`（旧 `IntegrityCheckView`）にあったロジックをそのまま移設したもので、
/// 挙動を変えていない。**
@MainActor
final class LocalIntegrityDataSource: IntegrityDataSource {
    private let database: Database
    private let bundleURL: URL
    private let appState: AppState?
    private var pendingReportBox: IntegrityReportBox?

    init(database: Database, bundleURL: URL, appState: AppState?) {
        self.database = database
        self.bundleURL = bundleURL
        self.appState = appState
    }

    /// `AllOpenLibrariesDataSource`/`AppStateLibraryDataSource` と同じ `ensureLibraryUUID()` を使う
    /// ―― registry のキー（library uuid 文字列）を HTTP ルートと完全に一致させるため。
    private var libraryUUID: String? { appState?.librarySettings?.ensureLibraryUUID() }

    var canStartScan: Bool { true }
    var scanUnavailableReason: String? { nil }

    func summary() async throws -> IntegritySummary {
        try database.integritySummary()
    }

    func lastScanAt() async throws -> Date? {
        guard let unix = try database.integrityLastCheckedAt() else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    func list(status: IntegrityStatus) async throws -> [IntegrityRow] {
        let fetched = try database.integrityRecords(status: status)
        return fetched.map { book, record in
            IntegrityRow(
                id: Int64(book.id),
                title: book.title,
                filename: book.path.map { URL(fileURLWithPath: $0).lastPathComponent },
                path: book.path,
                status: record.status,
                checkedAt: Date(timeIntervalSince1970: TimeInterval(record.checkedAt)),
                entryCount: record.entryCount,
                badEntries: record.badEntries,
                degraded: record.isDegraded)
        }
    }

    /// G27b 最終レビュー Fix2: `IntegrityScanTask` を自前で回すのではなく、CLI/MCP の
    /// `POST .../integrity/full-scan` と同じ `LocalControlController.shared.maintenanceRegistry`
    /// を通す（同じ job 名 `integrityFullScanJobName` で登録する）。`start` が false（他ジョブが
    /// 同一庫で実行中）を返すことは通常ここに来る前にボタンが無効化されているため稀だが、
    /// レースで到達しても registry が実際の多重起動を防いでくれる（自前ガードを重複させない）。
    func startScan(mode: FullScanMode) async throws -> Bool {
        guard let uuid = libraryUUID else { return false }
        let box = IntegrityReportBox()
        pendingReportBox = box
        // `self` を後段の `@Sendable` クロージャへ取り込まないよう、必要な値だけを
        // 事前にローカル定数へ写す（`database`/`bundleURL` は Sendable な値）。
        let db = database
        let libraryBundleURL = bundleURL
        let started = await LocalControlController.shared.maintenanceRegistry.start(
            library: uuid, job: integrityFullScanJobName
        ) { progress, isCancelled in
            try await withoutActuallyEscaping(isCancelled) { escapableIsCancelled in
                let report = try await FullIntegrityScanner.scan(
                    database: db, mode: mode,
                    deps: FullIntegrityScanner.liveDependencies(libraryBundleURL: libraryBundleURL),
                    progress: { d, t in progress(d, t) },
                    isCancelled: escapableIsCancelled)
                box.set(report)
                return report.scanned
            }
        }
        if !started {
            // busy（他ジョブが同一庫で実行中）。
            pendingReportBox = nil
        }
        return started
    }

    func cancel() async {
        guard let uuid = libraryUUID else { return }
        await LocalControlController.shared.maintenanceRegistry.cancel(library: uuid)
    }

    func jobProgress() async -> IntegrityJobProgress? {
        guard let uuid = libraryUUID else { return nil }
        guard let status = await LocalControlController.shared.maintenanceRegistry.status(library: uuid) else {
            return nil
        }
        return IntegrityJobProgress(job: status.job, done: status.done, total: status.total)
    }

    func takeCompletionReport() -> FullScanReport? {
        defer { pendingReportBox = nil }
        return pendingReportBox?.take()
    }
}

/// Phase G27b Task 6 / 最終レビュー Fix2: 整合性チェックウィンドウの「full-scan」ジョブ名。
/// CLI/MCP の HTTP ルート（`POST .../integrity/full-scan`）が `maintenanceRegistry.start` に
/// 渡す job 名（`Sources/LibraryServer/LibraryServerCore.swift`）と**文字列として完全一致**させる
/// こと。ここがずれると、GUI が開始したジョブを CLI の `GET maintenance/status` が別ジョブとして
/// 見てしまい（あるいはその逆）、"同じ registry を使っているのに busy 判定が食い違う" という
/// 一番検出しづらい形で Fix2 の意図が壊れる。（`IntegrityWindow.swift` から挙動不変で移設）
///
/// Phase G29 Task 1 review fixup: 値はそのまま（HTTP ルートと一致させる必要があるため改名しない）、
/// 可視性のみ `private` に戻した。このファイルの外（`IntegrityWindow.swift`）は
/// `IntegrityJobProgress.isIntegrityFullScan` 経由でのみ参照する。
private let integrityFullScanJobName = "full-scan"
