// SPDX-License-Identifier: MIT
import AppCore
import Foundation
import LibraryServer
import LibraryServerAPI
import LibraryStore
import RemoteClient

// Phase G29 Task 1: 破損チェックウィンドウのデータ源を抽象化する（挙動不変のリファクタリング）。
//
// このファイルは機能追加ではない。`IntegrityWindow.swift` が DB と
// `MaintenanceJobRegistry` を直接触っていた部分を、プロトコル越しに置き換えるための
// 型を定義する。ローカル実装（`LocalIntegrityDataSource`）は既存ロジックの移設であり、
// リモート実装（`RemoteIntegrityDataSource`）は Phase G29 Task 3 が追加する。

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

// MARK: - RemoteIntegrityDataSource（Phase G29 Task 3）

/// リモート庫の `IntegrityDataSource` 実装。`RemoteLibraryClient`（Task 2 で追加した 4 メソッド＋
/// 既存の `cancelMaintenance`）越しに HTTP でサーバの `book_integrity` を読み書きする。
///
/// - `client`/`libraryUUID`/`libraryToken`/`tier` は `IntegrityWindowContainer.resolveRemote` が
///   解決した値をそのまま受け取る（このデータ源自身は解決を行わない）。優先経路は
///   `RemoteLibraryRegistry` に既に開いている `RemoteLibraryState` を見つけてその
///   `libraryToken`/`tier` を再利用する（施錠庫でも解錠済みトークンをそのまま使える。
///   review Critical 1）。見つからないときのみ `ServerConnectionStore` フォールバックで
///   `libraryToken: nil`・`/me` 解決の `tier` になる。
/// - `tier` はコンテナが解決済みの値を渡す固定値。ウィンドウの寿命中にグラントの tier が
///   変わることは通常無く（変わるとすれば再接続が要る）、ローカル実装の
///   `LocalIntegrityDataSource` が `appState` 経由で `librarySettings` を都度読みに行くのとは
///   事情が異なる（ローカルは同一プロセス内の可変状態、こちらは解決済みの認可結果）。
@MainActor
final class RemoteIntegrityDataSource: IntegrityDataSource {
    private let client: RemoteLibraryClient
    private let libraryUUID: String
    private let libraryToken: String?
    private let tier: AccessTier
    /// review Minor 4: `ServerConnectionStore` フォールバック経路で `/me` 自体が失敗した
    /// （オフライン等）場合に true。「権限が足りない」と「権限を確認できない」は原因が違うため、
    /// `scanUnavailableReason` の文言を分けるためだけに使う。
    private let tierResolutionFailed: Bool

    init(client: RemoteLibraryClient, libraryUUID: String, libraryToken: String?, tier: AccessTier,
         tierResolutionFailed: Bool = false) {
        self.client = client
        self.libraryUUID = libraryUUID
        self.libraryToken = libraryToken
        self.tier = tier
        self.tierResolutionFailed = tierResolutionFailed
    }

    /// full-scan は admin 必須（サーバ側 `requireAdmin`）。summary/list は read で通る。
    /// 数十時間かかりうるジョブを閲覧権限で起動させないための意図的な段階的縮退（spec §3.4）。
    var canStartScan: Bool { tier >= .admin }
    var scanUnavailableReason: String? {
        guard !canStartScan else { return nil }
        if tierResolutionFailed {
            return "サーバに接続できないため、権限を確認できません。"
        }
        return "この接続には管理者権限がないため、スキャンを開始できません。"
    }

    func summary() async throws -> IntegritySummary {
        let reply = try await client.fetchIntegritySummary(libraryUUID: libraryUUID, libraryToken: libraryToken)
        return IntegritySummary(checked: reply.checked, unchecked: reply.unchecked,
                                 damaged: reply.damaged, degraded: reply.degraded)
    }

    /// `integrity/summary` は最終検査時刻を運ばない（サーバを変更しないという本フェーズの制約上、
    /// 新しいフィールドを追加できない）。素直に「取得できない」を返す — ビューは既に
    /// `lastScanAt: Date?` を optional として扱っているため、呼び出し側の分岐を増やさずに済む。
    func lastScanAt() async throws -> Date? { nil }

    func list(status: IntegrityStatus) async throws -> [IntegrityRow] {
        let reply = try await client.fetchIntegrityList(
            libraryUUID: libraryUUID, status: status.rawValue, libraryToken: libraryToken)
        return reply.items.compactMap(Self.mapRow)
    }

    /// 202=起動受理→true。409（他ジョブ実行中）は `RemoteClientError.server(409)` として投げられる
    /// （`RemoteLibraryClient.startIntegrityFullScan` のドキュメントコメント参照）ので、ここで
    /// `false` に写す ―― busy は失敗ではなく正常系（`LocalIntegrityDataSource.startScan` が
    /// registry の `start` が false を返すケースと同じ扱い）。それ以外のエラーはそのまま投げる。
    func startScan(mode: FullScanMode) async throws -> Bool {
        do {
            try await client.startIntegrityFullScan(libraryUUID: libraryUUID, mode: mode.wireValue, libraryToken: libraryToken)
            return true
        } catch RemoteClientError.server(409) {
            return false
        }
    }

    func cancel() async {
        try? await client.cancelMaintenance(libraryUUID: libraryUUID, libraryToken: libraryToken)
    }

    /// `running == false` は「今このライブラリで（このジョブ種別に限らず）何も走っていない」ので
    /// nil に写す。ローカルの `LocalControlController.shared.maintenanceRegistry.status(library:)`
    /// が実行中ジョブが無ければ nil を返すのと同じ意味に揃える。
    func jobProgress() async -> IntegrityJobProgress? {
        guard let reply = try? await client.fetchMaintenanceStatus(libraryUUID: libraryUUID, libraryToken: libraryToken) else {
            return nil
        }
        return Self.mapProgress(reply)
    }

    /// リモートには「自分がこのタブで開始したジョブの詳細レポートを取り出す」箱が無い
    /// （サーバはスキャンごとの詳細 `FullScanReport` を HTTP で公開していない）。これは
    /// Task 1 完了時点でレビュー済みの結論のとおり「未実装」ではなく「正しい答え」――
    /// 完了直後の詳細キャプションは出ないが、`reload()` による要約/一覧の更新は
    /// `jobProgress()` のポーリングで引き続き反映される。
    func takeCompletionReport() -> FullScanReport? { nil }

    // MARK: - 純粋な写像（HTTP を張らずにテストできるよう切り出したもの）

    /// `IntegrityItemDTO` → `IntegrityRow` の写像。未知の `status` 文字列の行は nil（＝スキップ）。
    ///
    /// `IntegrityItemDTO.status` はサーバが `IntegrityStatus.rawValue` から書いた文字列で、通常は
    /// 必ず既知のケースにデコードできる。ここで `IntegrityStatus(rawValue:)` が失敗するのは
    /// 「サーバが新しいステータス種別を追加し、このクライアントがまだ知らない」という将来の
    /// スキーマ前方互換の場合に限られる。未知値を安全な既知ケース（例: `.ok`）へ黙って倒すと、
    /// 実際にはもっと深刻な状態の本を「正常」と誤表示しかねない。一覧はあくまで `summary()`
    /// （サーバの一次集計）の内訳を見るための補助であり、一覧側だけが該当行を欠く方が、誤った
    /// 安全表示より安全側に倒れる ―― よって行ごとスキップする（握り潰さない: 呼び出し側の
    /// `compactMap` が nil を落とすだけで、例外にもログにもしないのは、summary の集計自体は
    /// 別エンドポイントから正しく取れており致命的ではないため）。
    ///
    /// review Minor 3: 現状のサーバ実装では `list(status:)` が `status.rawValue`（＝クライアントが
    /// 既に知る既知値）をクエリに渡し、サーバは**その status の行だけ**を返す
    /// （`LibraryServerCore.swift` の `integrity/list` ハンドラ）。したがって戻ってくる全行の
    /// `status` は実際には常に既知値で、この分岐は現状到達不能。それでも残すのは、将来サーバが
    /// 新しいステータス種別を追加したとき（クライアント側の対応漏れ）に無言で誤表示させない
    /// ための前方互換の防御として価値があるため。
    static func mapRow(_ item: IntegrityItemDTO) -> IntegrityRow? {
        guard let mappedStatus = IntegrityStatus(rawValue: item.status) else { return nil }
        return IntegrityRow(
            id: Int64(item.bookID),
            title: item.title,
            filename: item.filename,
            // path は常に nil。HTTP DTO はパスを運ばない（サーバ機のファイルシステム上の値で、
            // リモート機の Finder で開いても意味が無い）。ビューは path == nil で
            // 「Finder で表示」を出し分けるため、ここで特別扱いは不要。
            path: nil,
            status: mappedStatus,
            checkedAt: Date(timeIntervalSince1970: TimeInterval(item.checkedAt)),
            entryCount: item.entryCount,
            badEntries: item.badEntries,
            degraded: item.degraded)
    }

    /// `MaintenanceStatusReply` → `IntegrityJobProgress?` の写像。`running == false` は nil。
    static func mapProgress(_ reply: MaintenanceStatusReply) -> IntegrityJobProgress? {
        guard reply.running else { return nil }
        return IntegrityJobProgress(job: reply.job ?? "", done: reply.done ?? 0, total: reply.total ?? 0)
    }
}

// review Minor 2: 「2 台目の実機でしか落ちない」種類のコード（サーバ側の文字列と 1 文字でも
// ずれると 400 になる）なので、`private` のままテスト不可にはしない。internal にして
// `RemoteIntegrityDataSourceTests` から直接固定する。
extension FullScanMode {
    /// `POST integrity/full-scan` の `mode` 文字列。サーバ側 `parseFullScanMode`
    /// （`LibraryServerCore.swift`）と完全一致させること。
    var wireValue: String {
        switch self {
        case .uncheckedOnly: return "unchecked"
        case .all: return "all"
        case .damagedOnly: return "damaged"
        }
    }
}
