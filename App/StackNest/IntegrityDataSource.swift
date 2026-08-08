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
    /// 実行中ジョブの中断。失敗（権限不足・オフライン等）は例外を投げる ―― Phase G29 Task 3
    /// fix round 3: `try?` で握り潰すと、進捗が取得できず凍結表示中に「中断」を押しても
    /// 黙って何も起きない（それこそユーザーが押したくなるボタンなのに）。
    func cancel() async throws
    /// 実行中でなければ nil。取得自体に失敗した場合（権限不足・オフライン等）は例外を投げる ――
    /// Phase G29 Task 3 fix round 2: 取得失敗を「実行中でない」の顔をさせないため
    /// （review Critical 1 の同族。`try?` で握り潰すと「進捗なし」＝安全な状態と誤読される）。
    /// 呼び出し側（`IntegrityCheckView.startObserving()`）が明示的にエラー表示する。
    /// **ただし** admin 未満で見えないことが仕様上確定している場合（リモートの `tier < .admin`）は
    /// 例外にせず nil を返す ―― fix round 3: 「取得に失敗した」と「そもそも見えない仕様」を
    /// 区別しないと、read/edit 接続で常時エラーが出続ける恒久的な誤警報になる。
    func jobProgress() async throws -> IntegrityJobProgress?
    /// スキャンを開始できるか。リモートで admin 未満なら false。
    var canStartScan: Bool { get }
    /// `canStartScan` が false のときに表示する理由。true のときは nil。
    var scanUnavailableReason: String? { get }
    /// スキャン完了直後、**自分（このデータ源インスタンス）が開始したジョブ**の詳細レポートを
    /// 1 回だけ取り出す。他所（CLI/MCP・別ウィンドウ）が開始したジョブや、詳細レポートの概念が
    /// ない場合（リモート）は常に nil ―― `IntegrityReportBox` の仕組み（挙動不変で移設）。
    func takeCompletionReport() -> FullScanReport?
    /// `lastScanAt()` が意味のある答えを返せるか。false なら、その nil は「一度も検査していない」
    /// ではなく「そもそも取得できない」という意味 ―― Phase G29 Task 3 fix round 4
    /// (whole-branch review Important 1): ビュー側の語彙では nil は「未検査」を意味するため、
    /// 両者を混同するとフルスキャン済みの庫でも「最終検査: 未検査」という自己矛盾した断言になる。
    /// ローカルは常に true。
    ///
    /// 2026-08-08 smoke フィードバック: `integrity/summary` に `lastScanAt` フィールドが追加された
    /// ことで、リモートも**新サーバとの通信時は** true になりうる。ただし**旧サーバ（このフィールド
    /// を知らないビルド）はキー自体を返さない**ため、`false` のままになる ―― 「サーバが答えを
    /// 知らない」場合と「サーバは答えたが未検査」の場合を混同すると、まさに直前のバグの再演になる
    /// （`RemoteIntegrityDataSource.mapSummary`/`IntegritySummaryReply.lastScanAtKnown` 参照）。
    var supportsLastScanAt: Bool { get }
    /// ジョブ非実行時（アイドル時）のポーリング間隔（ナノ秒）。Phase G29 Task 3 fix round 4
    /// (whole-branch review Important 3): 400ms はローカルの in-process registry 呼び出し用に
    /// 選ばれた値で、ネットワーク越しの定数として妥当ではなかった（リモートは HTTP 往復のたびに
    /// サーバのメインアクタへホップする）。ローカルはコストが無いので実行中と同じ間隔のままでよい。
    var idlePollIntervalNanoseconds: UInt64 { get }
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
    var supportsLastScanAt: Bool { true }
    /// in-process の registry 読み取りはコストが無いので、実行中と同じ間隔のままでよい
    /// （`IntegrityCheckView.Self.activePollIntervalNanoseconds` と同値）。
    var idlePollIntervalNanoseconds: UInt64 { 400_000_000 }

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

    /// ローカルの registry 中断は失敗しうる操作ではない（`throws` はプロトコル都合で付いている
    /// だけで、実際に投げることはない）。
    func cancel() async throws {
        guard let uuid = libraryUUID else { return }
        await LocalControlController.shared.maintenanceRegistry.cancel(library: uuid)
    }

    /// ローカルの registry 読み取りは失敗しうる操作ではない（`throws` はプロトコル都合で付いている
    /// だけで、実際に投げることはない）。
    func jobProgress() async throws -> IntegrityJobProgress? {
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

/// リモートのデータ源が「サーバの答え」ではなく**クライアント側の事情**で応えられないとき投げる。
///
/// 通信エラーと区別する理由: 通信エラーは「サーバに聞いたが駄目だった」だが、これは
/// 「聞きに行く前提が崩れている」。ユーザーに促すべき操作も違う（再試行ではなく「更新」）。
enum RemoteIntegrityUnavailable: Error {
    /// 庫のウィンドウが閉じられ、権限を確認する術が無くなった状態。
    /// **確認できないことを「権限が無い」「実行中でない」に化けさせないため**に投げる。
    case permissionUnconfirmed
}

/// リモート庫の `IntegrityDataSource` 実装。`RemoteLibraryClient`（Task 2 で追加した 4 メソッド＋
/// 既存の `cancelMaintenance`）越しに HTTP でサーバの `book_integrity` を読み書きする。
///
/// Phase G29 Task 3 fix round 4 (Critical, whole-branch review C1): `libraryToken`/`tier` を
/// **値として一度だけ焼き付けるのをやめた**。以前は解決時点のスナップショットを保持していたため、
/// 施錠庫を解錠する前に窓を開くと「施錠されています」が永久に表示され続け（解錠しても直らない）、
/// `/me` 解決前（＝admin 判定が確定する前）に開くと実際は admin でもボタンが恒久的に無効になる
/// という 2 つの「読めなかった値を読めた事実として断言する」欠陥があった。
///
/// 優先経路（`init(client:libraryUUID:liveState:)`）は、`IntegrityWindowContainer.resolveRemote` が
/// `RemoteLibraryRegistry` から見つけた**生きている** `RemoteLibraryState` を弱参照し、
/// `libraryToken`/`tier` を呼び出しのたびに読む。これにより解錠・`/me` 完了・再接続に追従する
/// （`LocalIntegrityDataSource` が `appState` 経由で `librarySettings` を都度読むのと対称になった）。
/// フォールバック経路（`init(client:libraryUUID:libraryToken:tier:tierResolutionFailed:)`）は
/// `RemoteLibraryState` が見つからない場合（`ServerConnectionStore` 経由・実質到達不能）専用で、
/// 固定値のまま。
@MainActor
final class RemoteIntegrityDataSource: IntegrityDataSource {
    private let client: RemoteLibraryClient
    private let libraryUUID: String
    private weak var liveState: RemoteLibraryState?
    /// fix round 5 (Critical, whole-branch review — 弱参照が死んだ後の再発): live-state 経路で
    /// 構築されたかどうか。true のときは「`liveState` が生きている間だけ tier を確認できている」
    /// という判定にする ―― 弱参照がブラウズ窓のクローズで nil になった後も
    /// `fallbackTier`（`.read`）を「確認済みの事実」として騙らないため。
    private let constructedFromLiveState: Bool
    private let fallbackLibraryToken: String?
    private let fallbackTier: AccessTier
    /// `ServerConnectionStore` フォールバック経路で `/me` 自体が失敗した（オフライン等）場合に true。
    /// live-state 経路では常に false で init するが、`tierResolutionFailed`（computed）側で
    /// `liveState == nil` を見て上書きする。
    private let explicitTierResolutionFailed: Bool
    /// 2026-08-08 smoke フィードバック: `integrity/summary` が `lastScanAt` を運ぶようになった
    /// （旧サーバはこのキー自体を返さない）。直近の応答が実際にこのキーを含んでいたかを覚えておく
    /// ―― `supportsLastScanAt` の情報源。ウィンドウを開いた直後・まだ一度も応答を受け取っていない
    /// 間は「まだ確認していない」＝ `false`（不明側に倒す fail-closed。旧サーバの沈黙を
    /// 「未検査」と誤読しないため、このブランチが 6 ラウンドかけて除去した欠陥と同じ形を避ける）。
    private var lastScanAtKnown = false

    /// 優先経路: 生きている `RemoteLibraryState` を弱参照する（fix round 4, Critical 1）。
    init(client: RemoteLibraryClient, libraryUUID: String, liveState: RemoteLibraryState) {
        self.client = client
        self.libraryUUID = libraryUUID
        self.liveState = liveState
        self.constructedFromLiveState = true
        self.fallbackLibraryToken = nil
        self.fallbackTier = .read
        self.explicitTierResolutionFailed = false
    }

    /// フォールバック経路: `RemoteLibraryState` が見つからないときの固定値。
    init(client: RemoteLibraryClient, libraryUUID: String, libraryToken: String?, tier: AccessTier,
         tierResolutionFailed: Bool = false) {
        self.client = client
        self.libraryUUID = libraryUUID
        self.liveState = nil
        self.constructedFromLiveState = false
        self.fallbackLibraryToken = libraryToken
        self.fallbackTier = tier
        self.explicitTierResolutionFailed = tierResolutionFailed
    }

    /// `liveState` があれば常にそちらを優先（解錠直後・`/me` 完了直後の値を即座に反映するため、
    /// 値をキャッシュせず呼び出しのたびに読む）。
    private var libraryToken: String? { liveState?.libraryToken ?? fallbackLibraryToken }
    private var tier: AccessTier { liveState?.tier ?? fallbackTier }

    /// live-state 経由で構築され、かつその弱参照が死んでいるか（＝ tier をもう確認できないか）。
    ///
    /// fix round 5 (Critical, whole-branch review 再指摘): live-state 経路で構築されたインスタンスは、
    /// 弱参照が生きている間しか確認できていない。ブラウズ窓が閉じて `liveState` が nil になった
    /// 瞬間、`tier` は `fallbackTier`（`.read`）にフォールバックするが、**これは確認した事実ではない**
    /// ―― 実際は admin かもしれない接続を「管理者権限がない」と断言してはいけない
    /// （このバグの前身である Critical 1 とまったく同じ形。今度は弱参照が死んだ後に再発した）。
    /// フォールバック経路（`ServerConnectionStore`／`explicitTierResolutionFailed`）は元から
    /// `/me` の成否で判定しており、こちらとは原因が違うので文言も分ける（下記 `scanUnavailableReason`）。
    private var liveStateDied: Bool { constructedFromLiveState && liveState == nil }

    /// `lastScanAtKnown` をそのまま返す（直近の応答が実際に `lastScanAt` キーを含んでいたか）。
    /// まだ何も取得していない間は `false`（不明側の fail-closed 初期値）。
    var supportsLastScanAt: Bool { lastScanAtKnown }
    /// HTTP 往復のため、ジョブが無いときは大きく間隔を空ける（whole-branch review Important 3）。
    var idlePollIntervalNanoseconds: UInt64 { 3_000_000_000 }

    /// full-scan は admin 必須（サーバ側 `requireAdmin`）。summary/list は read で通る。
    /// 数十時間かかりうるジョブを閲覧権限で起動させないための意図的な段階的縮退（spec §3.4）。
    /// `liveStateDied` の間は `fallbackTier`（`.read`）が確認済みの値ではないため開始不可にする
    /// （fail-closed。fix round 5）。`tier >= .admin` は `liveStateDied` のとき常に `.read` なので
    /// 実質すでに false だが、「確認できていないから止める」という理由を明示的に書いておく。
    var canStartScan: Bool { !liveStateDied && tier >= .admin }
    var scanUnavailableReason: String? {
        guard !canStartScan else { return nil }
        if liveStateDied {
            // fix round 5: サーバへ接続できないわけではない（ブラウズ窓の参照を失っただけ）ので、
            // フォールバック経路の「サーバに接続できないため」という文言は使わない。「更新」で
            // 再解決すれば直る（`IntegrityWindowContainer.resolveRemoteDataSource` 参照）。
            return "権限を確認できません。「更新」を押してください。"
        }
        if explicitTierResolutionFailed {
            return "サーバに接続できないため、権限を確認できません。"
        }
        return "この接続には管理者権限がないため、スキャンを開始できません。"
    }

    func summary() async throws -> IntegritySummary {
        let reply = try await client.fetchIntegritySummary(libraryUUID: libraryUUID, libraryToken: libraryToken)
        let mapped = Self.mapSummary(reply)
        lastScanAtKnown = mapped.lastScanAtKnown
        return mapped.summary
    }

    /// 2026-08-08 smoke フィードバック: `integrity/summary` が `lastScanAt` を運ぶようになったため、
    /// 同じエンドポイントをもう一度叩いて取り出す（`list(status:)` 用の別エンドポイントは無い ―
    /// `summary()` の呼び出し順に依存しないよう、独立して取得する。2 count クエリだけの軽い
    /// エンドポイントなので、`reload()` が毎回 `summary()`→`lastScanAt()` の順で呼ぶことによる
    /// 二重取得は許容する）。
    ///
    /// `reply.lastScanAtKnown == false`（旧サーバ）のときは、値が `nil` でもそれを
    /// 「未検査」と読ませてはいけない ―― `supportsLastScanAt`（＝ `lastScanAtKnown`）を
    /// 同時に更新し、ビュー側は `dataSource.supportsLastScanAt` を見て「不明」と「未検査」を
    /// 区別する（`IntegrityWindowLogic.lastScanText` 参照）。
    func lastScanAt() async throws -> Date? {
        let reply = try await client.fetchIntegritySummary(libraryUUID: libraryUUID, libraryToken: libraryToken)
        let mapped = Self.mapSummary(reply)
        lastScanAtKnown = mapped.lastScanAtKnown
        return mapped.lastScanAt
    }

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

    /// Phase G29 Task 3 fix round 3 (Minor, review 再々指摘): `try?` で握り潰さず投げるようにした。
    /// 凍結された `jobStatus`（`jobProgress()` が失敗中）と組み合わさると、「中断」がまさに
    /// ユーザーが押したくなるボタンなのに黙って何もしない、という状態になっていた。
    /// `startScan` と同じ扱い（呼び出し側 `IntegrityCheckView.cancelScan()` が `scanErrorText` に表示）。
    func cancel() async throws {
        try await client.cancelMaintenance(libraryUUID: libraryUUID, libraryToken: libraryToken)
    }

    /// `running == false` は「今このライブラリで（このジョブ種別に限らず）何も走っていない」ので
    /// nil に写す。ローカルの `LocalControlController.shared.maintenanceRegistry.status(library:)`
    /// が実行中ジョブが無ければ nil を返すのと同じ意味に揃える。
    ///
    /// Phase G29 Task 3 fix round 2 (Minor, Critical 1 の同族): 取得自体の失敗（403/施錠・
    /// ネットワーク断等）はここで `try?` に握り潰さず、そのまま投げる。`maintenance/status` は
    /// admin 専用（`LibraryServerCore.swift` の `requireAdmin()`）なので、read/edit 接続は
    /// 常にここで失敗する ―― それを「実行中でない」という nil に化けさせない。
    ///
    /// Phase G29 Task 3 fix round 3 (Important, review 再々指摘): ↑の変更が新しい問題を作った ――
    /// read/edit 接続は「常にここで失敗する」ため、開いた瞬間からウィンドウを閉じるまで
    /// 「進捗を取得できません。」が消えずに出続け、隣の「管理者権限がないため…」と二重に警告する
    /// ことになっていた。tier 不足は「取得に失敗した」のではなく「そもそも見えない仕様」なので、
    /// HTTP を叩く前に tier を見て、admin 未満なら（例外を投げず）素直に nil を返す。
    /// これで read/edit 接続は 400ms ごとの無駄な HTTP 呼び出しも無くなる副次効果がある。
    /// tier が admin なのに実際には取得できない場合（オフライン等）は従来どおり投げる。
    /// Phase G29 fix round 6 (Important, whole-branch review NEW-4): `liveStateDied` を
    /// ここへ伝えていなかったため、**本フェーズの欠陥パターンの最後の 1 例**が残っていた ――
    /// live state が失われると tier は「未確認」なのに `tier >= .admin` が false になり、
    /// 「見に行けなかった」が「実行中でない」という nil に化けていた。
    /// 実害は大きい: スキャン実行中に庫のウィンドウを閉じると（**破損チェックウィンドウを
    /// 独立させたのは、まさに何時間も走るスキャン中に他の操作をできるようにするため**）、
    /// 3 秒以内に進捗・「検査中…」・中断ボタンがすべて消え、
    /// `wasRunning && status == nil` が完了分岐を発火させて、31 時間走っているジョブを
    /// 黙って「終わった」ものとして扱ってしまう。
    /// tier 不足（＝確認済みで見えない仕様）と、確認できない状態は区別しなければならない。
    func jobProgress() async throws -> IntegrityJobProgress? {
        guard !liveStateDied else { throw RemoteIntegrityUnavailable.permissionUnconfirmed }
        guard tier >= .admin else { return nil }
        let reply = try await client.fetchMaintenanceStatus(libraryUUID: libraryUUID, libraryToken: libraryToken)
        return Self.mapProgress(reply)
    }

    /// リモートには「自分がこのタブで開始したジョブの詳細レポートを取り出す」箱が無い
    /// （サーバはスキャンごとの詳細 `FullScanReport` を HTTP で公開していない）。これは
    /// Task 1 完了時点でレビュー済みの結論のとおり「未実装」ではなく「正しい答え」――
    /// 完了直後の詳細キャプションは出ないが、`reload()` による要約/一覧の更新は
    /// `jobProgress()` のポーリングで引き続き反映される。
    func takeCompletionReport() -> FullScanReport? { nil }

    // MARK: - 純粋な写像（HTTP を張らずにテストできるよう切り出したもの）

    /// `IntegritySummaryReply` → (`IntegritySummary`, 最終検査時刻, 「取得できたか」) の写像。
    /// `summary()`/`lastScanAt()` の両方がこれを経由する ―― 「ビューが実際に呼ぶのと同じ関数を
    /// テストする」（`mapRow`/`mapProgress` と同じ設計方針。ロジックを平行に複製したテストは
    /// このブランチの過去レビューで実欠陥を捕まえなかった実績があるため避ける）。
    ///
    /// `lastScanAtKnown`（DTO 側のフィールド、`contains(.lastScanAt)` から決まる）をそのまま
    /// `known` として返す ―― 旧サーバ（キー自体を送らない）との通信では常に `false` になり、
    /// 呼び出し側はこれを `supportsLastScanAt` として保持することで「未検査」と「不明」を
    /// 区別する。
    static func mapSummary(_ reply: IntegritySummaryReply) -> (summary: IntegritySummary, lastScanAt: Date?, lastScanAtKnown: Bool) {
        let summary = IntegritySummary(checked: reply.checked, unchecked: reply.unchecked,
                                        damaged: reply.damaged, degraded: reply.degraded)
        let lastScanAt = reply.lastScanAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return (summary, lastScanAt, reply.lastScanAtKnown)
    }

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
    ///
    /// review Minor 9: `job` は running=true なら現行サーバが必ず入れるため到達不能だが、
    /// 万一 nil で来た場合に空文字だと「他のメンテナンス処理を実行中です（）」という
    /// 中身の無い表示になる。`"unknown"` にして、少なくとも「ジョブ名が取れなかった」と
    /// 分かる形にしておく。
    static func mapProgress(_ reply: MaintenanceStatusReply) -> IntegrityJobProgress? {
        guard reply.running else { return nil }
        return IntegrityJobProgress(job: reply.job ?? "unknown", done: reply.done ?? 0, total: reply.total ?? 0)
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
