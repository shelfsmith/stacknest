// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore
import ArchiveAdapter
import Hummingbird
import NIOCore
import LibraryServerAPI
import StackroomFormat
import ImageIO
import OSLog

/// LibraryServer の設定（4.1b でアプリ設定 UI から渡される）。
public struct LibraryServerConfig: Sendable {
    public var host: String
    public var port: Int
    /// デバイス認証用の共有トークン（QR でクライアントに渡す）。読み取り（R）ロール。
    public var token: String
    /// 編集（RW）ロール用トークン。未生成は nil（その場合 RW 認証はできず R のみ）。
    public var editToken: String?
    /// 画像縮小器（既定は縮小しない Passthrough）。App は ImageIOTranscoder を注入する。
    public var transcoder: any ImageTranscoding
    /// 本ごと pageDirection が未設定のときの既定方向（アプリ起動時にスナップショット）。
    /// manifest エンドポイントが null を返さずに実効方向を返すために使う（4.1c）。
    public var defaultPageDirection: PageDirection
    /// 本のメタデータをサーバ経由で変更したとき App に通知する（libraryUUID, bookID）。
    /// App は該当ライブラリのインメモリ本モデルを DB から更新して GUI（詳細ペイン等）へ反映する。
    public var onBookChanged: (@Sendable (String, Int) -> Void)?
    /// 4.2c-6a: ライブラリ設定（スタンプ定義など）をサーバ経由で変更したとき App に通知する
    /// （libraryUUID）。App は該当ライブラリのインメモリ設定を DB から再読込して GUI に反映する。
    public var onLibrarySettingsChanged: (@Sendable (String) -> Void)?
    /// 実ファイルをゴミ箱へ送る注入関数（macOS は FileManager.trashItem を注入）。
    /// nil のとき DELETE ?trash=true は拒否（Linux/ヘッドレス portable のため core は直接 trash しない）。
    /// G16 A3: 戻り値はゴミ箱内での実ファイルの行き先（FileManager.trashItem の resultingItemURL）。
    /// DELETE ハンドラがこれを TrashRestoreTracker に記録し、restore がサーバー側の記録のみを
    /// 使ってファイルを元の場所へ移動し戻す（クライアント供給パスは使わない・G16 A3 セキュリティ修正）。
    public var trashFile: (@Sendable (URL) throws -> URL?)?
    /// 本の追加/削除など行集合が変わったとき App に通知する（libraryUUID）。App は該当ライブラリの
    /// 表示リストを全リロードする（onBookChanged はメタ更新用で行の挿入/削除は反映できないため）。
    public var onLibraryStructureChanged: (@Sendable (String) -> Void)?
    /// true でアプリ Web UI を配信せず /docs（Redoc）を / に出す（ローカルエンドポイント用）。
    public var apiOnly: Bool
    /// true のとき、提示トークン（R/W いずれも）を admin tier として扱う（LAN 信頼環境向け）。
    public var adminTier: Bool
    /// グラント解決クロージャ（毎リクエスト現在値を返す＝ライブ反映・C-③a）。
    /// nil = 旧来の token/editToken 経路。本番は { GrantStore.list() } を注入する。
    public var grantsProvider: (@Sendable () -> [Grant])?
    /// G23 (m4): grant の読み書きを集約するリポジトリ。設定すると CRUD の read/write が
    /// 両方ここを通り、`grantsProvider` 未設定なら認証もここから読む（read と write が同じ源）。
    /// nil = 従来どおり `GrantStore`（UserDefaults.standard）を直接使う。
    public var grantRepository: (any GrantRepository)?
    /// G12b-3a: 監視フォルダの「今すぐスキャン」がリクエストされたとき App に通知する（libraryUUID）。
    /// App は該当ライブラリの FolderWatcher の scanNow() を発火する。
    public var onScanNowRequested: (@Sendable (String) -> Void)?
    /// G21 #6-2: true のとき `buildApplication()` が起動時に古い実行時 temp（`stacknest-arc-*`,
    /// 24h TTL）を掃除する。既定は false — `buildApplication()` は `swift test` から ~90 箇所で
    /// 直接呼ばれるため、既定 true にすると実マシンの実 `$TMPDIR` を毎テスト実行のたびに触ってしまう
    /// （実運用の他インスタンスの temp を誤って掃除しかねない）。実サーバ起動経路
    /// （ServerController.start / LocalControlController.startIfEnabled）だけが true を渡す。
    public var sweepRuntimeTempOnStartup: Bool
    /// G27b Task7: `/local/libraries/open` `/local/libraries/close` ルートを登録するかどうか。
    /// 任意パスを開ける API は実質的なファイルシステム探索になるため、**既定は false**。
    /// true にできるのは `LocalControlController`（127.0.0.1 専用）だけ — `ServerController`
    /// （共有サーバ）は絶対に true にしないこと。これがルートの有無そのものを分ける唯一のゲートで、
    /// フラグが false の buildApplication() はこのルートを一切登録しない（tier 判定より手前の防御・
    /// 共有サーバ側では 404 になる）。
    public var enableLocalLibraryControl: Bool
    /// 庫を「開く」実装（App 層が注入）。既存の GUI ウィンドウ経路（openWindow）に乗せるため、
    /// 実装はロック取得・初回起動・状態復元をすべて App 層に委ねる。戻り値は開いた（または既に
    /// 開いていた）庫の UUID。失敗は `LocalLibraryControlError` を投げること（App 層は Hummingbird
    /// を知らなくて済むよう、ルートハンドラ側でこれを HTTPError にマップする）。
    public var openLibrary: (@Sendable (URL) async throws -> String)?
    /// 庫を「閉じる」実装（App 層が注入）。該当 UUID のウィンドウを閉じる。
    public var closeLibrary: (@Sendable (String) async throws -> Void)?
    // dual-stack 化は呼び出し側が host: "::" を明示注入する
    // （Linux は v6only sysctl 依存のため既定は互換性優先の 0.0.0.0）。
    public init(host: String = "0.0.0.0", port: Int, token: String,
                editToken: String? = nil,
                transcoder: any ImageTranscoding = PassthroughTranscoder(),
                defaultPageDirection: PageDirection = .rightToLeft,
                onBookChanged: (@Sendable (String, Int) -> Void)? = nil,
                onLibrarySettingsChanged: (@Sendable (String) -> Void)? = nil,
                trashFile: (@Sendable (URL) throws -> URL?)? = nil,
                onLibraryStructureChanged: (@Sendable (String) -> Void)? = nil,
                apiOnly: Bool = false,
                adminTier: Bool = false,
                grantsProvider: (@Sendable () -> [Grant])? = nil,
                grantRepository: (any GrantRepository)? = nil,
                onScanNowRequested: (@Sendable (String) -> Void)? = nil,
                sweepRuntimeTempOnStartup: Bool = false,
                enableLocalLibraryControl: Bool = false,
                openLibrary: (@Sendable (URL) async throws -> String)? = nil,
                closeLibrary: (@Sendable (String) async throws -> Void)? = nil) {
        self.host = host
        self.port = port
        self.token = token
        self.editToken = editToken
        self.transcoder = transcoder
        self.defaultPageDirection = defaultPageDirection
        self.onBookChanged = onBookChanged
        self.onLibrarySettingsChanged = onLibrarySettingsChanged
        self.trashFile = trashFile
        self.onLibraryStructureChanged = onLibraryStructureChanged
        self.apiOnly = apiOnly
        self.adminTier = adminTier
        self.grantsProvider = grantsProvider
        self.grantRepository = grantRepository
        self.onScanNowRequested = onScanNowRequested
        self.sweepRuntimeTempOnStartup = sweepRuntimeTempOnStartup
        self.enableLocalLibraryControl = enableLocalLibraryControl
        self.openLibrary = openLibrary
        self.closeLibrary = closeLibrary
    }
}

/// G27b Task7: ローカル制御のライブラリ開閉クロージャ（`LibraryServerConfig.openLibrary` /
/// `closeLibrary`）が投げるエラー。App 層は Hummingbird 型を知らずに済み、
/// LibraryServerCore 側のルートハンドラがこれを適切な HTTPError にマップする。
public enum LocalLibraryControlError: Error, Sendable {
    /// 指定パスが存在しない、またはライブラリバンドルとして妥当でない。
    case invalidPath(String)
    /// close で指定した UUID の庫が（このプロセス内で）開いていない。
    case notFound
    /// open 後、庫のロード完了（AppState 登録）を待ったがタイムアウトした。
    case timeout
    /// アプリの起動が完了しておらず openWindow を呼べる状態にない（起動直後の極めて短い窓）。
    case bridgeUnavailable
}

/// LibraryServer 共通の RequestContext。JSON の Date を ISO8601 に固定する
/// （Hummingbird 2.25 の既定も ISO8601 だが、upstream の既定変更に依存しないよう明示。
/// テスト側デコーダも .iso8601 で一致させること — plan 設計ノート）。
public struct LibraryRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    /// 提示トークンのロール。BearerAuthMiddleware が認証成功時に刻む（既定 .read）。
    public var role: TokenRole = .read
    /// アクセス階層（read/edit/admin）。BearerAuthMiddleware が認証成功時に刻む（既定 .read）。
    public var tier: AccessTier = .read
    /// グラントで許可されたライブラリスコープ。BearerAuthMiddleware が認証成功時に刻む（既定 .all）。
    public var scope: GrantScope = .all
    /// G23 (M3): 認証された主体の識別子（grant の id）。unlock のレート制限を principal 単位に
    /// するために使う。**トークンの生値は入れない**。固定トークン経路では `"legacy"` のまま。
    public var grantID: String = "legacy"

    public init(source: Source) {
        self.coreContext = .init(source: source)
    }

    public var requestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public var responseEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// BearerAuthMiddleware が値型コンテキストへロールと tier を刻めるよう、role/tier/scope を get/set 可能にする制約。
/// 認証ミドルウェアはこの protocol への準拠だけを要求し、具体コンテキストに依存しない。
public protocol RoleHoldingContext {
    var role: TokenRole { get set }
    var tier: AccessTier { get set }
    var scope: GrantScope { get set }
    /// G23 (M3): 認証された主体の識別子（grant の id・固定トークン経路は "legacy"）。
    var grantID: String { get set }
}
extension LibraryRequestContext: RoleHoldingContext {}

extension RoleHoldingContext {
    /// .edit 以上の tier でなければ 403 を投げる。
    public func requireEdit() throws { guard tier >= .edit else { throw HTTPError(.forbidden) } }
    /// .admin tier（最高位）でなければ 403 を投げる。`>=` は将来 tier 追加時の安全側既定。
    public func requireAdmin() throws { guard tier >= .admin else { throw HTTPError(.forbidden) } }
}

/// ファセット / ブラウズで受け付ける列名の許可リスト（SQL injection 防御・4.2b-1b-2b）。
/// BrowserPaneState.BrowseField.allCases から生成するため enum の変更に自動追従する。
let allowedFacetColumns: Set<String> = Set(
    BrowserPaneState.BrowseField.allCases.map { $0.sqlColumn }
)

/// #5: books ページングの `page` 上限。`(page - 1) * per` が Int をオーバーフローしないよう、
/// `per` の最大クランプ値（500・BooksQuery 構築時に `min(500, ...)` で保証）を基準に、
/// `(page - 1) * 500` が Int.max を超えない最大の page を許容する。実データの total は
/// 遥かに小さいため、この上限を超えるページは既存の「start >= total → 空スライス」に必ず乗る
/// （正当な小さい page 値の挙動は変えない・regression なし）。
let maxSafeBooksPage: Int = Int.max / 500

/// #3: `inner` スコープが `outer` スコープの部分集合かどうか（grants 一覧/PATCH/DELETE の scope フィルタで使用）。
/// - `outer == .all`（グローバル admin）: 常に true（全 grant を閲覧/操作できる）。
/// - `outer == .libraries(...)`（scope 限定 admin）:
///   - `inner == .all` は false とする（.all は「無制限」であり、限定スコープの部分集合ではない。
///     ここを true にすると scope 限定 admin が全ライブラリ共有トークンを閲覧/削除できてしまう）。
///   - `inner == .libraries(...)` は `inner` の UUID 集合が `outer` の UUID 集合の部分集合なら true。
/// GrantScope に他の containment/allows ヘルパが無いため、ここに最小実装を追加する。
func grantScopeIsContained(_ inner: GrantScope, within outer: GrantScope) -> Bool {
    switch outer {
    case .all:
        return true
    case .libraries(let outerUUIDs):
        switch inner {
        case .all:
            return false
        case .libraries(let innerUUIDs):
            return Set(innerUUIDs).isSubset(of: Set(outerUUIDs))
        }
    }
}

/// HTTP サーバ本体。Router 構築と Application 生成を担う。
/// AppKit / ImageIO / PDFKit を import しないこと（Linux 移植規律・spec §3.2）。
public struct LibraryServerCore: Sendable {
    private static let backupLogger = Logger(subsystem: "app.shelfsmith.stacknest", category: "Backup")
    /// G23 (m4): サーバ構成の警告用（grant の読み書き経路の競合など）。
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "LibraryServerCore")
    public let config: LibraryServerConfig
    let dataSource: any LibraryServerDataSource
    /// ロック庫の短命トークン（メモリのみ・再起動で失効）。
    let tokenStore = LibraryTokenStore()
    /// G23 (#9/#10): URL クエリ用の短命セッショントークン（EventSource / `<img>` 向け）。
    let sessionTokenStore = SessionTokenStore()
    /// #2: ロック庫 unlock のブルートフォース抑止（ライブラリ単位の失敗回数＋ロックアウト）。
    public let unlockRateLimiter = UnlockRateLimiter()
    /// 本ごとの BookContent ハンドルキャッシュ（アーカイブ再オープン排除・spec §3.3）。
    let contentCache = BookContentCache(ttlSeconds: 300)
    /// G8a: ライブ同期の配信ハブ。/events が subscribe し、mutation が publish する。
    /// G23 (#15): 施錠庫のイベント粒度を落とすため、init で施錠判定クロージャを注入する。
    public let eventHub: EventHub
    /// G12b-3b: メンテナンスジョブ（メタ補完/表紙圧縮）の per-library レジストリ。
    /// SSE への配線は construction 時に同期的に行う（Codex review Important #1・詳細は
    /// MaintenanceJobRegistry.init のコメント参照）。
    public let maintenanceRegistry: MaintenanceJobRegistry
    /// G16 A3 セキュリティ修正: trash-undo のファイル移動元/移動先をサーバー側でのみ記録する
    /// （クライアント供給パスを信用しない。詳細は TrashRestoreTracker のドキュメントコメント）。
    let trashTracker = TrashRestoreTracker()
    /// G16 Codex High セキュリティ修正: restore がクライアント供給 path を無条件に信用しないための
    /// 土台（詳細は DeletedBookPathTracker のドキュメントコメント）。
    let deletedPathTracker = DeletedBookPathTracker()
    /// G16 Codex Medium 修正: PATCH の resolve→pre-image→updateBook を (uuid,bookID) 単位で直列化する
    /// （詳細は PerBookSerializer のドキュメントコメント）。
    let patchSerializer = PerBookSerializer()

    /// G27b 最終レビュー Fix2: `maintenanceRegistry` を外部から注入できるようにする。
    ///
    /// 既定（nil）は従来どおり construction 時に自前で 1 個作る（テスト・`ServerController` は
    /// これでよい）。`LocalControlController` だけは、アプリプロセス生存中ずっと生き続ける
    /// 自前の registry インスタンスを毎回同じものを渡す ―― これが CLI/MCP の HTTP ルート
    /// （`POST .../integrity/full-scan` 等）と GUI の整合性チェックウィンドウを**同じ
    /// registry**に揃える唯一の接続点になる（詳細は `LocalControlController.maintenanceRegistry`
    /// のコメント参照）。注入された registry の `onProgress`/`onFinished` はその registry が
    /// construction された時点の eventHub に固定されたまま変わらない（このコア自身の
    /// eventHub には配線し直さない）。ローカル制御の SSE `/events` はこのアプリ内では
    /// どこからも購読されていない（`/events` を使うのは `RemoteLibraryState` = リモート共有
    /// クライアントのみ）ため実害はない。CLI/MCP は `GET maintenance/status` のポーリングで
    /// 進捗を確認する設計（31 時間規模の走査で SSE を張り続けない）なので、この経路は
    /// もともと SSE に依存していない。
    public init(config: LibraryServerConfig, dataSource: any LibraryServerDataSource,
                maintenanceRegistry: MaintenanceJobRegistry? = nil) {
        self.config = config
        self.dataSource = dataSource
        // G23 (#15): 施錠庫の bookChanged は bookID を落として配信する（蔵書数の概算が漏れるため）。
        self.eventHub = EventHub(isLibraryLocked: { [dataSource] uuid in
            await dataSource.servedLibraries().first(where: { $0.uuid == uuid })?.isLocked ?? false
        })
        if let maintenanceRegistry {
            self.maintenanceRegistry = maintenanceRegistry
        } else {
            let eventHub = self.eventHub
            self.maintenanceRegistry = MaintenanceJobRegistry(
                onProgress: { lib, job, done, total in
                    Task { await eventHub.publish(.maintenanceProgress(library: lib, job: job, done: done, total: total)) }
                },
                onFinished: { lib, job, outcome, count in
                    Task { await eventHub.publish(.maintenanceFinished(library: lib, job: job, outcome: outcome, count: count)) }
                    // 完了で一覧/表紙を 1 回更新（compress-covers は表紙が変わる）。
                    Task { await eventHub.publish(.structureChanged(library: lib)) }
                }
            )
        }
    }

    /// G8a: 本のメタデータ変更を App コールバック＋EventHub の両方へ通知する（progress は除外・呼出元判断）。
    private func notifyBookChanged(_ uuid: String, _ bookID: Int) {
        config.onBookChanged?(uuid, bookID)
        Task { await eventHub.publish(.bookChanged(library: uuid, bookID: bookID)) }
    }
    /// G8a: ライブラリ構造変更（追加/削除/relink 等）を App コールバック＋EventHub の両方へ通知する。
    private func notifyStructureChanged(_ uuid: String) {
        config.onLibraryStructureChanged?(uuid)
        Task { await eventHub.publish(.structureChanged(library: uuid)) }
    }
    /// G8a: ライブラリ設定変更（ラベル/スタンプ/watch/lock 等）を App コールバック＋EventHub の両方へ通知する。
    private func notifySettingsChanged(_ uuid: String) {
        config.onLibrarySettingsChanged?(uuid)
        Task { await eventHub.publish(.settingsChanged(library: uuid)) }
    }

    /// G27a Task6: DELETE lock 用の任意ボディを緩く読む。
    /// `request.decode(as:context:)` は空ボディを `DecodingError.dataCorrupted` → 400 に写像するため、
    /// そのまま使うと「ロックが無い庫への無ボディ DELETE」という既存の後方互換な呼び方まで壊れる。
    /// 空ボディは「現パスワード無し」（nil）として扱い、非空だが不正な JSON のときだけ 400 にする。
    private static func decodeOptionalLockRemoveBody(
        _ request: Request, context: LibraryRequestContext
    ) async throws -> String? {
        let buffer = try await request.body.collect(upTo: context.maxUploadSize)
        guard buffer.readableBytes > 0 else { return nil }
        let data = Data(buffer.readableBytesView)
        do {
            return try JSONDecoder().decode(LockRemoveRequest.self, from: data).currentPassword
        } catch {
            throw HTTPError(.badRequest)
        }
    }

    /// G27b Task5: full-scan 起動リクエストの mode 文字列を `FullScanMode` に写像する。
    /// 未知の値は 400 で拒否する（`.uncheckedOnly` へ黙って落とすと、CLI/MCP の指定ミスに
    /// 気づけないまま 31 時間の走査が始まってしまう）。
    private static func parseFullScanMode(_ raw: String) throws -> FullScanMode {
        switch raw {
        case "unchecked": return .uncheckedOnly
        case "all": return .all
        case "damaged": return .damagedOnly
        default: throw HTTPError(.badRequest, message: "mode は unchecked/all/damaged のいずれかです（受信: \(raw)）")
        }
    }

    /// G16 Codex Medium: (libraryUUID, bookID) 単位で臨界区間を直列化するヘルパ。
    /// acquire → body 実行 → release を保証する（body が throw しても release は必ず呼ばれる。
    /// デッドロックしないよう、body の中で同じ key を再度 acquire してはいけない）。
    private func withBookPatchLock<T>(uuid: String, bookID: Int, _ body: () async throws -> T) async throws -> T {
        await patchSerializer.acquire(uuid: uuid, bookID: bookID)
        do {
            let result = try await body()
            await patchSerializer.release(uuid: uuid, bookID: bookID)
            return result
        } catch {
            await patchSerializer.release(uuid: uuid, bookID: bookID)
            throw error
        }
    }

    public func buildApplication() -> some ApplicationProtocol {
        // G21 #6-2: 強制終了で残った実行時 temp を起動時に掃除する（24h TTL・best-effort）。
        // `buildApplication()` はテストからも ~90 箇所直接呼ばれるため、実サーバ起動経路が
        // 明示的に config.sweepRuntimeTempOnStartup = true を渡したときだけ実行する
        // （既定 false・詳細は LibraryServerConfig のコメント参照）。
        if config.sweepRuntimeTempOnStartup {
            TempSweeper.sweepRuntimeTemp()
        }
        let router = Router(context: LibraryRequestContext.self)
        // /server/info は認証不要（ペアリング前の到達性確認用）。
        let transcodes = config.transcoder.supportsScaling
        router.get("/api/v1/server/info") { _, _ in
            var caps = ServerCapabilities.inApp
            caps.transcode = transcodes
            return caps
        }
        // G23 (m4): grant の書き込み先。未指定なら従来どおり UserDefaults.standard を使う。
        let grantRepo: any GrantRepository = config.grantRepository ?? UserDefaultsGrantRepository()
        // 認証で使う grant の読み口。
        //
        // G23 Codex Medium #5: **repository が指定されていれば、read も write もそれ 1 本に統一する**。
        // 以前は `grantsProvider` を優先していたため、両方指定すると read は provider・write は
        // repository という split-brain 構成が作れた（CRUD が 200 を返しても認証や GET に反映されない）。
        // 両方指定は設定ミスなので、黙って一方を選ばず警告を出したうえで repository を採る。
        // どちらも無ければ旧来の token/editToken 直接照合へ落ちる（既存挙動）。
        if config.grantsProvider != nil && config.grantRepository != nil {
            Self.logger.warning("""
                grantsProvider と grantRepository の両方が指定されています。read/write が別経路になるのを\
                避けるため grantRepository を優先し、grantsProvider は無視します。
                """)
        }
        let effectiveGrantsProvider: (@Sendable () -> [Grant])? = {
            if config.grantRepository != nil { return { grantRepo.all() } }
            return config.grantsProvider
        }()
        // それ以外の API は Bearer トークン認証配下。
        let sessionTokenStore = self.sessionTokenStore
        let api = router.group("api/v1")
            .add(middleware: BearerAuthMiddleware(token: config.token, editToken: config.editToken, adminTier: config.adminTier, grantsProvider: effectiveGrantsProvider, sessionTokenStore: sessionTokenStore))

        // G23 (#9/#10): 永続 grant token を URL に載せないため、短命セッショントークンへ交換する。
        // 発行は Authorization ヘッダでの認証を要求する（クエリ経由の発行は受け付けない）。
        api.post("session") { request, _ in
            guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else {
                throw HTTPError(.unauthorized)
            }
            let grantToken = String(header.dropFirst("Bearer ".count))
            return SessionReply(sessionToken: await sessionTokenStore.issue(grantToken: grantToken),
                                expiresIn: SessionTokenStore.defaultTTLSeconds)
        }
        let dataSource = self.dataSource
        let tokenStore = self.tokenStore
        let unlockRateLimiter = self.unlockRateLimiter
        let resolver = LibraryResolver(dataSource: dataSource, tokenStore: tokenStore)
        // 提示トークンの tier（read/edit/admin）と role（互換）、スコープを返す（4.2b-3・B1・B2b）。
        api.get("me") { _, context in
            MeReply(tier: context.tier, scope: context.scope)
        }
        // グラント CRUD（admin 専用）。CRUD は GrantStore(UserDefaults.standard) を更新し、
        // 認証は grantsProvider が毎リクエスト GrantStore を参照するため即時反映される（C-③a）。
        api.get("grants") { _, context in
            try context.requireAdmin()
            // #3: scope 限定 admin には自分の scope に含まれる（⊆）grant のみを返す。
            // グローバル admin（scope == .all）は従来どおり全 grant を見る。
            // grant のソースは認証と同じ config.grantsProvider（本番は { GrantStore.list() }＝挙動同一）
            // を用い、CRUD と認証で参照元を一致させる（provider 未設定時のみ GrantStore へフォールバック）。
            return (effectiveGrantsProvider?() ?? grantRepo.all())
                .filter { grantScopeIsContained($0.scope, within: context.scope) }
                .map {
                    GrantDTO(id: $0.id, label: $0.label, token: $0.token, tier: $0.tier, scope: $0.scope)
                }
        }
        api.post("grants") { request, context in
            try context.requireAdmin()
            let req = try await request.decode(as: GrantCreateRequest.self, context: context)
            // Codex Critical: 作成する grant の scope/tier が呼出者の権限を超えてはならない。
            // これが無いと、庫限定 admin が `tier: admin, scope: all` の grant を発行して
            // 全ライブラリを掌握できる（#3 の一覧フィルタを迂回する権限昇格）。
            guard grantScopeIsContained(req.scope, within: context.scope) else {
                throw HTTPError(.forbidden)
            }
            guard req.tier <= context.tier else { throw HTTPError(.forbidden) }
            let g = Grant(id: UUID().uuidString, label: req.label,
                          token: ServerPreferences.generateToken(),
                          tier: req.tier, scope: req.scope, createdAt: Date())
            grantRepo.upsert(g)
            return GrantDTO(id: g.id, label: g.label, token: g.token, tier: g.tier, scope: g.scope)
        }
        api.patch("grants/:id") { request, context in
            try context.requireAdmin()
            let id = try context.parameters.require("id")
            guard var g = (effectiveGrantsProvider?() ?? grantRepo.all()).first(where: { $0.id == id }) else {
                throw HTTPError(.notFound)
            }
            // #3: scope 外の grant は 404（存在の有無を漏らさない・GET 一覧と同じ containment）。
            guard grantScopeIsContained(g.scope, within: context.scope) else {
                throw HTTPError(.notFound)
            }
            let req = try await request.decode(as: GrantUpdateRequest.self, context: context)
            // Codex Critical: 更新「後」の scope/tier も呼出者の権限内でなければならない
            // （対象 grant が scope 内でも、`.all` や別ライブラリへ広げれば昇格になるため）。
            if let s = req.scope {
                guard grantScopeIsContained(s, within: context.scope) else { throw HTTPError(.forbidden) }
            }
            if let t = req.tier {
                guard t <= context.tier else { throw HTTPError(.forbidden) }
            }
            if let l = req.label { g.label = l }
            if let t = req.tier  { g.tier  = t }
            if let s = req.scope { g.scope = s }
            grantRepo.upsert(g)
            return GrantDTO(id: g.id, label: g.label, token: g.token, tier: g.tier, scope: g.scope)
        }
        api.delete("grants/:id") { _, context in
            try context.requireAdmin()
            let id = try context.parameters.require("id")
            guard let g = (effectiveGrantsProvider?() ?? grantRepo.all()).first(where: { $0.id == id }) else {
                throw HTTPError(.notFound)
            }
            // #3: scope 外の grant は 404（GET/PATCH と同じ containment。存在の有無を漏らさない）。
            guard grantScopeIsContained(g.scope, within: context.scope) else {
                throw HTTPError(.notFound)
            }
            grantRepo.delete(id: id)
            return HTTPResponse.Status.noContent
        }
        api.get("libraries") { _, context in
            let libs = await dataSource.servedLibraries().filter { context.scope.allows($0.uuid) }
            return libs.map {
                LibraryDTO(id: $0.uuid, name: $0.name, locked: $0.isLocked,
                           bookCount: (try? $0.db.fetchBookCount()) ?? 0)
            }
        }
        // ロック庫の解錠: パスワード照合に成功したら短命ライブラリトークンを発行。
        // 注意: Body/Reply はファイルスコープに置く（クロージャ内ローカル型を戻り値にすると
        // swiftc の ASTMangler が無限再帰でクラッシュするため）。
        api.post("libraries/:lib/unlock") { request, context in
            let uuid = try context.parameters.require("lib")
            // #2a: scope 外のライブラリは 404（/libraries 一覧・resolver と同じ写像）。
            // .forbidden ではなく .notFound にすることで、scope 外の grant に対して
            // 「その uuid のライブラリが存在するかどうか」自体を漏らさない（existence oracle 防止）。
            guard context.scope.allows(uuid) else { throw HTTPError(.notFound) }
            guard let lib = await dataSource.servedLibraries().first(where: { $0.uuid == uuid }) else {
                throw HTTPError(.notFound)
            }
            // #2: ブルートフォース抑止。連続失敗が閾値超なら一定時間 429 で拒否する。
            // G23 (M3): 数える単位は library＋principal。library 単体だと、閲覧トークンを渡した
            // 相手が失敗を繰り返すだけで正当な所有者を締め出せてしまう。
            //
            // G23 Codex High #2: 判定と枠の確保を **actor 内で原子的に**行う。以前は判定と
            // 失敗記録の間に PBKDF2 検証（actor 外・意図的に重い）が挟まっており、同時要求が
            // すべて記録前のゲートを通過できた（レート制限の迂回＋CPU 枯渇）。
            let principal = context.grantID
            switch await unlockRateLimiter.beginAttempt(uuid, principal: principal) {
            case .lockedOut(let retryAfter), .tooManyConcurrent(let retryAfter):
                throw HTTPError(.tooManyRequests, headers: [.retryAfter: String(retryAfter)])
            case .granted:
                break
            }
            // 枠を取ったら、どの経路で抜けても必ず返す。
            let body: UnlockRequestBody
            do {
                body = try await request.decode(as: UnlockRequestBody.self, context: context)
            } catch {
                // 本文不正は試行として数えない（失敗回数を増やさずに枠だけ返す）。
                await unlockRateLimiter.finishAttempt(uuid, principal: principal, success: true)
                throw error
            }
            // G25d: 照合した credential 世代を受け取り、その世代にトークンを束縛する。
            let credential = lib.verifiedCredential(for: body.password)
            await unlockRateLimiter.finishAttempt(uuid, principal: principal, success: credential != nil)
            guard let credential else { throw HTTPError(.forbidden) }
            return UnlockReply(libraryToken: await tokenStore.issueToken(for: uuid, credential: credential))
        }
        // books 一覧（ページング・検索・ソート・進行状況・scope/filter/browse）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/books") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            let qp = request.uri.queryParameters
            let sortRaw = qp.get("sort") ?? "title"
            guard let sort = BookSortKey(rawValue: sortRaw) else { throw HTTPError(.badRequest) }
            // order は明示時のみ尊重。不正値（asc/desc 以外）は 400。
            let order: SortOrder
            if let orderRaw = qp.get("order") {
                guard let o = SortOrder(rawValue: orderRaw) else { throw HTTPError(.badRequest) }
                order = o
            } else {
                order = sort.defaultOrder
            }
            // ?filter=<URL-encoded JSON FilterState> — decode or use empty default.
            let filter = try decodeFilterState(from: qp.get("filter"))
            // ?browse=<URL-encoded JSON [[column,value]]> — 不正列名は 400（SQL injection 防御）。
            let browse = try decodeBrowseConstraintsValidated(from: qp.get("browse"))
            // ?fields=genre,neta,... — 応答に追加する任意フィールド（許可外は無視）。
            let allowedFields: Set<String> = ["genre", "neta", "keywordA", "keywordB", "keywordC", "memo"]
            let extraFields = Set((qp.get("fields") ?? "")
                .split(separator: ",").map(String.init)).intersection(allowedFields)
            let query = BooksQuery(
                q: qp.get("q"),
                sort: sort,
                order: order,
                // #5: page はオーバーフロー防御のため maxSafeBooksPage で上限クランプする
                // （実データの total は遥かに小さいため、正当な page 値の挙動は変わらない）。
                page: min(maxSafeBooksPage, max(1, qp.get("page", as: Int.self) ?? 1)),
                per: min(500, max(1, qp.get("per", as: Int.self) ?? 100)),
                scope: decodeSidebarScope(scope: qp.get("scope"), scopeId: qp.get("scopeId", as: Int64.self), recentDays: qp.get("recentDays", as: Int.self)),
                filter: filter,
                browse: browse,
                extraFields: extraFields
            )
            return try query.run(on: lib)
        }
        // 棚一覧（ユーザー棚・スマート棚）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/shelves") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            let rows = try lib.db.fetchAllShelves()
            // G13/F1: リモートサイドバー件数。手動棚/お気に入り=playlist 所属数、スマート棚=条件評価数。
            // ローカル AppState:549 (smartShelfBookCount) / SidebarView:129 (fetchPlaylistBookCount) と同型。
            return rows.map { row in
                let scope: SidebarScope = row.isSmart
                    ? .smartShelf(playlistID: row.id)
                    : (row.kind == "favorites" ? .favorites(playlistID: row.id) : .shelf(playlistID: row.id))
                let count = (try? lib.db.searchBooks(query: "", sidebarScope: scope).count) ?? 0
                return ShelfDTO(id: row.id, title: row.title, kind: row.kind, isSmart: row.isSmart, bookCount: count)
            }
        }
        // A1: 棚の作成（RW・手動 or スマート）。
        api.post("libraries/:lib/shelves") { [self] request, context in
            try context.requireEdit()
            let lib = try await resolver.resolveLibrary(request, context)
            let body = try await request.decode(as: ShelfCreateRequest.self, context: context)
            let newID: Int64
            if body.isSmart {
                guard let conditions = body.conditions else { throw HTTPError(.badRequest) }
                newID = try lib.db.createSmartShelf(title: body.title, conditions: conditions)
            } else {
                if body.conditions != nil { throw HTTPError(.conflict) }
                newID = try lib.db.createUserShelf(title: body.title)
            }
            self.notifySettingsChanged(lib.uuid)
            let row = try lib.db.fetchAllShelves().first(where: { $0.id == newID })
            return row.map { ShelfDTO(id: $0.id, title: $0.title, kind: $0.kind, isSmart: $0.isSmart) }
                ?? ShelfDTO(id: newID, title: body.title, kind: "user", isSmart: body.isSmart)
        }
        // A1: 棚の更新（RW・改名＋スマート条件更新）。
        api.patch("libraries/:lib/shelves/:id") { [self] request, context in
            try context.requireEdit()
            let shelfID = try context.parameters.require("id", as: Int64.self)
            let lib = try await resolver.resolveLibrary(request, context)
            guard let row = try lib.db.fetchAllShelves().first(where: { $0.id == shelfID }) else { throw HTTPError(.notFound) }
            let body = try await request.decode(as: ShelfUpdateRequest.self, context: context)
            // 先に全ガードを検証（partial-write 防止）。
            if body.conditions != nil, !row.isSmart { throw HTTPError(.conflict) }
            if body.title != nil, row.kind == "favorites" { throw HTTPError(.conflict) }
            var changed = false
            if let conditions = body.conditions {
                try lib.db.updateSmartShelfConditions(id: shelfID, conditions: conditions)
                changed = true
            }
            if let title = body.title {
                try lib.db.renameShelf(id: shelfID, title: title)
                changed = true
            }
            if changed { self.notifySettingsChanged(lib.uuid) }
            let updated = try lib.db.fetchAllShelves().first(where: { $0.id == shelfID })
            return updated.map { ShelfDTO(id: $0.id, title: $0.title, kind: $0.kind, isSmart: $0.isSmart) }
                ?? ShelfDTO(id: shelfID, title: body.title ?? row.title, kind: row.kind, isSmart: row.isSmart)
        }
        // A1: 棚の削除（RW・お気に入り棚は 409 で保護）。
        api.delete("libraries/:lib/shelves/:id") { [self] request, context in
            try context.requireEdit()
            let shelfID = try context.parameters.require("id", as: Int64.self)
            let lib = try await resolver.resolveLibrary(request, context)
            guard let row = try lib.db.fetchAllShelves().first(where: { $0.id == shelfID }) else { throw HTTPError(.notFound) }
            if row.kind == "favorites" { throw HTTPError(.conflict) }
            try lib.db.deleteShelf(id: shelfID)
            self.notifySettingsChanged(lib.uuid)
            return Response(status: .noContent)
        }
        // A1: スマート棚の条件取得（read）。
        api.get("libraries/:lib/shelves/:id/conditions") { request, context in
            let shelfID = try context.parameters.require("id", as: Int64.self)
            let lib = try await resolver.resolveLibrary(request, context)
            guard let row = try lib.db.fetchAllShelves().first(where: { $0.id == shelfID }) else { throw HTTPError(.notFound) }
            guard row.isSmart else { throw HTTPError(.conflict) }
            guard let conditions = try lib.db.fetchSmartShelfConditions(id: shelfID) else { throw HTTPError(.notFound) }
            return conditions
        }
        // A1: スマート棚の条件更新（RW）。
        api.put("libraries/:lib/shelves/:id/conditions") { [self] request, context in
            try context.requireEdit()
            let shelfID = try context.parameters.require("id", as: Int64.self)
            let lib = try await resolver.resolveLibrary(request, context)
            guard let row = try lib.db.fetchAllShelves().first(where: { $0.id == shelfID }) else { throw HTTPError(.notFound) }
            guard row.isSmart else { throw HTTPError(.conflict) }
            let conditions = try await request.decode(as: SmartShelfConditions.self, context: context)
            try lib.db.updateSmartShelfConditions(id: shelfID, conditions: conditions)
            self.notifySettingsChanged(lib.uuid)
            return conditions
        }
        // A1: 手動棚への所属追加（RW・スマート棚は 409）。
        api.post("libraries/:lib/shelves/:id/books") { [self] request, context in
            try context.requireEdit()
            let shelfID = try context.parameters.require("id", as: Int64.self)
            let lib = try await resolver.resolveLibrary(request, context)
            guard let row = try lib.db.fetchAllShelves().first(where: { $0.id == shelfID }) else { throw HTTPError(.notFound) }
            guard !row.isSmart else { throw HTTPError(.conflict) }
            let body = try await request.decode(as: ShelfBooksRequest.self, context: context)
            try lib.db.appendBooksToShelf(playlistID: shelfID, bookIDs: body.bookIDs)
            self.notifyStructureChanged(lib.uuid)
            return Response(status: .noContent)
        }
        // A1: 手動棚からの所属除去（RW・スマート棚は 409）。
        api.delete("libraries/:lib/shelves/:id/books") { [self] request, context in
            try context.requireEdit()
            let shelfID = try context.parameters.require("id", as: Int64.self)
            let lib = try await resolver.resolveLibrary(request, context)
            guard let row = try lib.db.fetchAllShelves().first(where: { $0.id == shelfID }) else { throw HTTPError(.notFound) }
            guard !row.isSmart else { throw HTTPError(.conflict) }
            let body = try await request.decode(as: ShelfBooksRequest.self, context: context)
            try lib.db.removeBooksFromShelf(playlistID: shelfID, bookIDs: body.bookIDs)
            self.notifyStructureChanged(lib.uuid)
            return Response(status: .noContent)
        }
        // ファセット（列の distinct 値リスト）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/facets/:field") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            let field = try context.parameters.require("field")
            guard allowedFacetColumns.contains(field) else { throw HTTPError(.badRequest) }
            let qp = request.uri.queryParameters
            let filter = try decodeFilterState(from: qp.get("filter"))
            let browse = try decodeBrowseConstraintsValidated(from: qp.get("browse"))
            let values = try lib.db.distinctValues(
                forColumn: field,
                query: qp.get("q") ?? "",
                sidebarScope: decodeSidebarScope(scope: qp.get("scope"), scopeId: qp.get("scopeId", as: Int64.self), recentDays: qp.get("recentDays", as: Int.self)),
                filter: filter,
                browserConstraints: browse.map { (column: $0.0, value: $0.1) }
            )
            return values
        }
        // BookRow → BookDetailDTO 変換ヘルパ（/detail と PATCH エンドポイントで共用）。
        // G16 A2: previous は PATCH エンドポイント限定（それ以外の呼び出しは省略=nil のまま）。
        @Sendable func makeBookDetailDTO(from row: BookRow, lastPage: Int? = nil, previous: BookPatchDTO? = nil) -> BookDetailDTO {
            BookDetailDTO(
                id: row.id, title: row.title, author: row.author, genre: row.genre, path: nil,
                dateAdded: row.dateAdded, playDate: row.playDate, bookType: row.bookType,
                fileType: row.fileType, pages: row.pages, lastPage: lastPage,
                rating: row.rating, unseen: row.unseen,
                keywordA: row.keywordA, keywordB: row.keywordB, keywordC: row.keywordC,
                neta: row.neta, memo: row.memo, series: row.series, volume: row.volume,
                coverImageName: row.coverImageName,
                coverCropRectJSON: row.coverCropRect.map(BookRow.encodeCoverCropRect),
                pageDirection: row.pageDirection.map { directionString($0) },
                // 4.2c-6b: path 自体は秘匿。拡張子だけ返してリモートの「ファイル形式」表示に使う。
                fileExtension: row.path.map { ($0 as NSString).pathExtension.lowercased() },
                // G12b-3a Task 6: basename のみ返す（フルパスは秘匿のまま）。
                filename: row.path.map { ($0 as NSString).lastPathComponent },
                previous: previous
            )
        }

        // G12b-3c S5: BookRow ⇄ BookRestoreDTO 変換ヘルパ（DELETE 応答／POST books/restore の body で共用）。
        // coverCropRect は x/y/w/h、pageDirection は directionString(_:) と同じ "ltr"/"rtl" 文字列、
        // Date は epoch 秒に写像する（LibraryRequestContext の .iso8601 デコーダ/エンコーダの影響を受けないため）。
        @Sendable func makeBookRestoreDTO(row: BookRow, hasCover: Bool) -> BookRestoreDTO {
            BookRestoreDTO(
                id: row.id, title: row.title, author: row.author, genre: row.genre, path: row.path,
                dateAdded: row.dateAdded.timeIntervalSince1970,
                playDate: row.playDate?.timeIntervalSince1970,
                bookType: row.bookType, fileType: row.fileType, pages: row.pages,
                rating: row.rating, unseen: row.unseen,
                keywordA: row.keywordA, keywordB: row.keywordB, keywordC: row.keywordC,
                neta: row.neta, memo: row.memo, series: row.series, volume: row.volume,
                coverImageName: row.coverImageName,
                coverCropX: row.coverCropRect.map { Double($0.origin.x) },
                coverCropY: row.coverCropRect.map { Double($0.origin.y) },
                coverCropW: row.coverCropRect.map { Double($0.size.width) },
                coverCropH: row.coverCropRect.map { Double($0.size.height) },
                pageDirection: row.pageDirection.map { directionString($0) },
                contentHash: row.contentHash, fileSize: row.fileSize, fileMtime: row.fileMtime,
                hasCover: hasCover
            )
        }
        // BookRestoreDTO → BookRow 逆変換（POST books/restore の各要素を Database.restoreBook に渡す前段）。
        @Sendable func bookRow(from dto: BookRestoreDTO) -> BookRow {
            let crop: CGRect?
            if let x = dto.coverCropX, let y = dto.coverCropY, let w = dto.coverCropW, let h = dto.coverCropH {
                crop = CGRect(x: x, y: y, width: w, height: h)
            } else {
                crop = nil
            }
            let direction: PageDirection?
            switch dto.pageDirection {
            case "rtl": direction = .rightToLeft
            case "ltr": direction = .leftToRight
            default: direction = nil
            }
            return BookRow(
                id: dto.id, title: dto.title, author: dto.author, genre: dto.genre, path: dto.path,
                dateAdded: Date(timeIntervalSince1970: dto.dateAdded),
                playDate: dto.playDate.map { Date(timeIntervalSince1970: $0) },
                bookType: dto.bookType, fileType: dto.fileType, pages: dto.pages,
                rating: dto.rating, unseen: dto.unseen,
                keywordA: dto.keywordA, keywordB: dto.keywordB, keywordC: dto.keywordC,
                neta: dto.neta, memo: dto.memo, series: dto.series, volume: dto.volume,
                coverImageName: dto.coverImageName, coverCropRect: crop, pageDirection: direction,
                contentHash: dto.contentHash, fileSize: dto.fileSize, fileMtime: dto.fileMtime
            )
        }

        // G16 Codex High: restore の path 検証用「許可ルート」集合。
        // BookImporter.add はローカル任意パスを受け付ける（監視フォルダに限らない取り込みが正規）ため、
        // 本の正当な path を特定の 1 箇所に決め打ちできない。代わりに、このライブラリが実際に
        // 参照/管理しているディレクトリ群を広めに集める:
        //   1. ライブラリバンドル自身のツリー（バンドル内に本体を持つ運用がある）
        //   2. 監視フォルダの各パス（watched_folders 設定）
        //   3. 現存する他の本のディレクトリ（フォルダ単位の取り込みが典型的なため、多くの場合
        //      兄弟本が同じディレクトリを指す）
        // これは deletedPathTracker（同一サーバーインスタンスでの実削除記録）が使えないとき
        // （サーバー再起動・別セッション等）の代替検証としてのみ使う。
        @Sendable func allowedRestoreRoots(lib: ServedLibrary) -> [String] {
            var roots: [String] = [lib.bundleURL.standardizedFileURL.path]
            let watchedJSON = (try? lib.db.getLibrarySetting(key: "watched_folders")) ?? nil
            let watched: [WatchedFolder] = watchedJSON.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([WatchedFolder].self, from: $0) } ?? []
            roots.append(contentsOf: watched.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
            let existingDirs = ((try? lib.db.fetchAllBooks()) ?? []).compactMap { $0.path }
                .map { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path }
            roots.append(contentsOf: existingDirs)
            return roots
        }
        // path が roots のいずれかの内側（ルート自身 or その配下）かどうかを、パス構成要素の境界で
        // 比較する（"/foo/bar" が "/foo/barbaz" を誤って許可しないように文字列 hasPrefix は使わない）。
        @Sendable func isPathWithinAllowedRoots(_ path: String, roots: [String]) -> Bool {
            // 相対パスは許可ルート判定が曖昧（プロセスの cwd 依存）になるため受け付けない。
            guard path.hasPrefix("/") else { return false }
            // Codex High: `standardizedFileURL` は `.`/`..` を字句的に畳むだけで symlink を解決しない。
            // 許可ルート配下に外部を指す symlink があると、字句比較では「ルート内」と誤判定し、
            // 続く GET .../file が symlink 先の実体（例: ~/.ssh/id_rsa）を返してしまう。
            // target・root の双方を実体（canonical path）へ解決してから比較する。
            let comps = URL(fileURLWithPath: path).standardizedFileURL
                .resolvingSymlinksInPath().pathComponents
            for root in roots {
                let rootComps = URL(fileURLWithPath: root).standardizedFileURL
                    .resolvingSymlinksInPath().pathComponents
                guard rootComps.count <= comps.count else { continue }
                if Array(comps.prefix(rootComps.count)) == rootComps { return true }
            }
            return false
        }

        // BookRow → BookListItemDTO 変換ヘルパ（adjacent / duplicate scan 等で共用）。
        // lastPage は DB アクセスが必要なため nil 固定。呼び出し側で .withLastPage(...) を付与する。
        @Sendable func makeBookListItemDTO(from row: BookRow) -> BookListItemDTO {
            BookListItemDTO(
                id: row.id, title: row.title, author: row.author,
                series: row.series, volume: row.volume,
                rating: row.rating, unseen: row.unseen, bookType: row.bookType,
                pages: row.pages,
                lastPage: nil,
                lastReadAt: nil,
                dateAdded: row.dateAdded,
                hasCover: false, coverVersion: nil,
                filename: row.path.map { ($0 as NSString).lastPathComponent }
            )
        }

        // 書籍詳細（フル BookRow の全フィールドを BookDetailDTO として返す）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/books/:id/detail") { request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let lastPage = (try? lib.db.loadViewerState(bookID: row.id))?.lastPage
            return makeBookDetailDTO(from: row, lastPage: lastPage)
        }
        // 書籍メタデータ更新（RW トークン専用・表紙フィールドは対象外）。
        // role=write でなければ 403、resolve で 404/401 を返す既存ルーティングを再利用。
        api.patch("libraries/:lib/books/:id") { [self] request, context in
            try context.requireEdit()
            let (lib, row0) = try await resolver.resolveBook(request, context)
            let dto = try await request.decode(as: BookPatchDTO.self, context: context)
            var patch = BookPatch()
            patch.title = dto.title
            patch.author = dto.author
            patch.genre = dto.genre
            patch.neta = dto.neta
            patch.memo = dto.memo
            patch.keywordA = dto.keywordA
            patch.keywordB = dto.keywordB
            patch.keywordC = dto.keywordC
            patch.rating = dto.rating
            patch.unseen = dto.unseen
            patch.series = dto.series
            patch.volume = dto.volume
            patch.bookType = dto.bookType
            patch.pageDirection = dto.pageDirection.flatMap { s -> PageDirection? in
                switch s {
                case "rtl": return .rightToLeft
                case "ltr": return .leftToRight
                default: return nil
                }
            }
            patch.clearSeries = dto.clearSeries
            patch.clearVolume = dto.clearVolume
            patch.clearPageDirection = dto.clearPageDirection
            // G16 Codex Medium: resolve→pre-image→updateBook の臨界区間を (uuid,bookID) 単位で
            // 直列化する。resolveBook で読んだ row0 はロック取得前の値なので pre-image には使わず、
            // ロックを取った後で本を読み直した row を使う（同じ本への同時 PATCH が同じ古い
            // pre-image を握ったまま片方が他方の編集結果を undo で巻き戻すのを防ぐ。別の本への
            // PATCH は並行のまま）。
            return try await self.withBookPatchLock(uuid: lib.uuid, bookID: row0.id) {
                guard let row = try lib.db.fetchBook(id: row0.id) else { throw HTTPError(.notFound) }
                // G16 A2: DB 更新前に、今回リクエストで変更対象になったフィールドだけを
                // pre-image として集める。クライアントはこれで undo の逆パッチを
                // キャッシュ非依存に組み立てられる。
                var previous = BookPatchDTO()
                if dto.title != nil { previous.title = row.title }
                if dto.author != nil { previous.author = row.author }
                if dto.genre != nil { previous.genre = row.genre }
                if dto.neta != nil { previous.neta = row.neta }
                if dto.memo != nil { previous.memo = row.memo }
                if dto.keywordA != nil { previous.keywordA = row.keywordA }
                if dto.keywordB != nil { previous.keywordB = row.keywordB }
                if dto.keywordC != nil { previous.keywordC = row.keywordC }
                if dto.rating != nil { previous.rating = row.rating }
                if dto.unseen != nil { previous.unseen = row.unseen }
                if dto.series != nil || dto.clearSeries { previous.series = row.series }
                if dto.volume != nil || dto.clearVolume { previous.volume = row.volume }
                if dto.bookType != nil { previous.bookType = row.bookType }
                if dto.pageDirection != nil || dto.clearPageDirection {
                    previous.pageDirection = row.pageDirection.map { directionString($0) }
                }
                try lib.db.updateBook(id: row.id, patch: patch)
                self.notifyBookChanged(lib.uuid, row.id)
                let updated = (try? lib.db.fetchBook(id: row.id)) ?? row
                return makeBookDetailDTO(from: updated, previous: previous)
            }
        }
        // 4.2c-6a: スタンプ定義の取得（R）。配信バンドル設定DB の stamp_definitions を返す。
        api.get("libraries/:lib/stamp-definitions") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            let json = (try? lib.db.getLibrarySetting(key: "stamp_definitions")) ?? nil
            let map: [String: [String]] = json
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
            return StampDefinitionsDTO(definitions: map)
        }
        // 4.2c-6a: スタンプ定義の置換（RW）。許可カラムのみ採用しマップ全体を保存。
        api.put("libraries/:lib/stamp-definitions") { [self] request, context in
            try context.requireEdit()
            let lib = try await resolver.resolveLibrary(request, context)
            let dto = try await request.decode(as: StampDefinitionsDTO.self, context: context)
            let allowed: Set<String> = ["genre", "neta", "keyword_a", "keyword_b", "keyword_c"]
            let filtered = dto.definitions.filter { allowed.contains($0.key) }
            let data = try JSONEncoder().encode(filtered)
            try lib.db.setLibrarySetting(key: "stamp_definitions", value: String(decoding: data, as: UTF8.self))
            // ローカル(同バンドルを開いている AppState)のインメモリ設定を再読込させる（C1' ライブ反映）。
            self.notifySettingsChanged(lib.uuid)
            return StampDefinitionsDTO(definitions: filtered)
        }
        // 4.2c-6a: 一括スタンプ適用（RW・append/clear をサーバ側で MultiValueParser/clearBookField）。
        api.post("libraries/:lib/books/stamp") { [self] request, context in
            try context.requireEdit()
            let lib = try await resolver.resolveLibrary(request, context)
            let body = try await request.decode(as: StampApplyRequest.self, context: context)
            let updated: Int
            do {
                updated = try applyStampToBooks(db: lib.db, field: body.field, value: body.value,
                                                clear: body.clear ?? false, bookIDs: body.bookIDs)
            } catch is StampApplyError {
                throw HTTPError(.badRequest)
            }
            for id in body.bookIDs { self.notifyBookChanged(lib.uuid, id) }
            return StampApplyReply(updated: updated)
        }
        // 4.2d-2: ローカルパスのファイルをライブラリに追加（in-place・admin）。
        api.post("libraries/:lib/books") { [self] request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let body = try await request.decode(as: AddBooksRequestDTO.self, context: context)
            let raw = FilenameFormatResolver.resolveRaw(database: lib.db, presetID: body.presetID)
            let format = (try? FilenameFormat(raw: raw)) ?? (try! FilenameFormat(raw: "@title"))
            let importer = BookImporter(database: lib.db, bundleURL: lib.bundleURL, format: format)
            let urls = body.paths.map { URL(fileURLWithPath: $0) }
            // A2: 取り込み設定は per-library override ?? グローバル既定をリクエスト時に解決する
            // （config の起動時スナップショットではなく、リモート設定変更を即時反映するため）。
            let acOverride = ((try? lib.db.getLibrarySetting(key: ImportDefaults.libAutoClassifyKey)) ?? nil).map { $0 == "1" || $0 == "true" }
            let thOverride = ((try? lib.db.getLibrarySetting(key: ImportDefaults.libThickThresholdKey)) ?? nil).flatMap { Int($0) }
            let result = await importer.add(
                urls: urls,
                autoClassifyEnabled: ImportDefaults.effectiveAutoClassify(override: acOverride),
                thickThreshold: ImportDefaults.effectiveThickThreshold(override: thOverride))
            // 行が増えるので全リロード通知（onBookChanged はメタ更新用で新規行に効かない）。
            if !result.addedIDs.isEmpty { self.notifyStructureChanged(lib.uuid) }
            return AddBooksReplyDTO(
                addedIDs: result.addedIDs,
                alreadyPresent: result.alreadyPresent.map { $0.path },
                failed: result.failed.map { $0.0.path })
        }
        // 4.2d-2: 本をライブラリから削除（エントリ＋サムネ）。?trash=true は admin 専用・edit は DB 削除のみ。
        // ?trash=true で実ファイルをゴミ箱へ（config.trashFile 注入時のみ・失敗は 500＝DB 不変・完全削除はしない）。
        api.delete("libraries/:lib/books/:id") { [self] request, context in
            // tier ゲートは解決より前（PATCH と一貫・read ユーザーへ存在情報を漏らさない）。
            let wantTrash = request.uri.queryParameters.get("trash").map { $0 == "true" || $0 == "1" } ?? false
            if wantTrash { try context.requireAdmin() } else { try context.requireEdit() }
            let (lib, row) = try await resolver.resolveBook(request, context)
            // G16 A3 セキュリティ修正: trash 削除時、実ファイルがゴミ箱内で行き着いた先
            // （resultingItemURL）はクライアントへ返す DTO には載せず、サーバー内部の trashTracker
            // にのみ記録する（restore がクライアント供給パスを信用して任意ファイルを移動できないよう
            // にするため。Arbitrary File Move via Client-Controlled Paths 対策）。
            if wantTrash {
                guard let trashFile = self.config.trashFile else { throw HTTPError(.notImplemented) }
                if let p = row.path {
                    let resultingURL: URL?
                    do { resultingURL = try trashFile(URL(fileURLWithPath: p)) }
                    catch { throw HTTPError(.internalServerError) }
                    if let resultingURL {
                        await self.trashTracker.record(uuid: lib.uuid, bookID: row.id, trashedURL: resultingURL, originalPath: p)
                    }
                }
            }
            try lib.db.deleteBook(id: row.id)
            // G16 Codex High: このサーバーが実際に削除した本の原本 path を記録する（trash の有無に
            // 関わらず）。restore がクライアント供給 dto.path をそのまま信用しないための土台
            // （詳細は DeletedBookPathTracker のドキュメントコメント）。
            if let p = row.path {
                await self.deletedPathTracker.record(uuid: lib.uuid, bookID: row.id, path: p)
            }
            let thumbDir = lib.bundleURL.appendingPathComponent("Thumbnails").appendingPathComponent(String(row.id))
            // G12b-3d smoke fix: サムネイル削除の前に表紙有無を捕捉し restore DTO に載せる
            // （restore 時にこれが true の本のみ再生成＝無表紙本に表紙を付けない）。
            // Codex G12b-3d Low: ディレクトリ存在ではなく thumbnail.jpg 実体で判定する
            // （regen がディレクトリ作成後に書込失敗した空ディレクトリを表紙ありと誤認しない）。
            let hadCover = FileManager.default.fileExists(atPath: coverURL(bundleURL: lib.bundleURL, bookID: row.id).path)
            try? FileManager.default.removeItem(at: thumbDir)
            // 行が消えるので全リロード通知（削除済み本は onBookChanged で扱えない）。
            self.notifyStructureChanged(lib.uuid)
            // G12b-3c S5: リモート undo のため、削除した行を BookRestoreDTO として返す（200＋body）。
            return makeBookRestoreDTO(row: row, hasCover: hadCover)
        }
        // G12b-3c S5: リモート undo（削除の取り消し）。DELETE が返した BookRestoreDTO 配列をそのまま渡すと
        // restoreBook が同じ id で再挿入する。G16 A3 セキュリティ修正: trash=true 削除でファイルが
        // trashTracker に記録されている場合、DB 行復元に加えて実ファイルをゴミ箱から元の path へ
        // 移動し戻す。ファイル移動はサーバーが記録した (trashedURL, originalPath) のみを使い、
        // dto.trashedPath / dto.path のようなクライアント供給値は一切使わない。
        // G16 Codex High セキュリティ修正: dto.path 自体も無条件には信用しない。deletedPathTracker
        // （同一サーバーインスタンスでの実削除記録）と一致する場合のみ全面的に信頼し、記録が無い
        // 場合は許可ルート（監視フォルダ／バンドルツリー／現存する他本のディレクトリ）に収まって
        // いるかで代替検証する。どちらも満たさない path は「危険」として neutralize する
        // （DB 行は復元するが path は落とし、regenerateThumbnail も呼ばない＝後続の
        // DELETE ?trash=true がその行を任意ファイル移動に使えないようにする）。
        api.post("libraries/:lib/books/restore") { [self] request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let dtos = try await request.decode(as: [BookRestoreDTO].self, context: context)
            let roots = allowedRestoreRoots(lib: lib)
            var restoredCount = 0
            var restoredIDs: [Int] = []
            for dto in dtos {
                // path 検証: サーバー記録（deletedPathTracker）が最優先の真実。あればそれを使い、
                // dto.path は無視する（クライアント供給値より常にサーバー記録を優先）。記録が無い
                // 場合のみ dto.path を許可ルートで検証する。
                var effectiveDTO = dto
                var pathIsSafe = true
                // Codex High fix: サーバー記録は peek（非破壊）で参照し、consume（take）は restoreBook
                // 成功後に行う。衝突で restoreBook が throw しても記録を失わない（trashTracker と同形）。
                let trackedPath = await self.deletedPathTracker.peek(uuid: lib.uuid, bookID: dto.id)
                if let trackedPath {
                    effectiveDTO.path = trackedPath
                } else if let p = dto.path {
                    pathIsSafe = isPathWithinAllowedRoots(p, roots: roots)
                    if !pathIsSafe { effectiveDTO.path = nil }
                }
                do {
                    try lib.db.restoreBook(bookRow(from: effectiveDTO))
                    restoredCount += 1
                    restoredIDs.append(dto.id)
                    // 復元成功時のみサーバー記録を consume（一度きり）。
                    if trackedPath != nil { await self.deletedPathTracker.take(uuid: lib.uuid, bookID: dto.id) }
                    // G16 A3 セキュリティ修正: trashTracker に記録があり、そのファイルが存在し、
                    // サーバーが記録した元 path が空いていれば、ゴミ箱から元の場所へ移動し戻す
                    // （degraded-safe: 元 path 占有・ゴミ箱側不在・記録なし〔サーバー再起動や
                    // DB-only 削除〕などは握り潰し／スキップし、DB 復元自体は成立させる＝
                    // ここで throw しない）。移動元/移動先は trashTracker 自身の記録のみを使うため
                    // dto.path の安全性に関わらず正しい場所へ戻る。
                    if let entry = await self.trashTracker.take(uuid: lib.uuid, bookID: dto.id),
                       FileManager.default.fileExists(atPath: entry.trashedURL.path),
                       !FileManager.default.fileExists(atPath: entry.originalPath) {
                        try? FileManager.default.moveItem(atPath: entry.trashedURL.path, toPath: entry.originalPath)
                    }
                    // G12b-3d smoke fix: ローカル undo（DB 復元＋file regenerate）と parity。
                    // 削除時に表紙があった本は、ソースアーカイブからサムネイルを再生成する
                    // （DB-only 削除はソース健在）。best-effort＝再生成失敗（ソース欠損＝trash 削除後や
                    // 抽出不可）は握り潰し、DB 復元自体は成立させる。path が未検証で危険な場合は
                    // アーカイブを一切開かない（任意ファイル読み取りの芽を摘む）。
                    if dto.hasCover == true, pathIsSafe {
                        // Bug B fix (G21 #5 smoke follow-up): decide *before* calling
                        // regenerateThumbnail whether this restore will hit the external→auto
                        // fallback branch — mirrors regenerateThumbnail's own no-op condition
                        // (`isExternal(fresh.coverImageName) && fileExists(url.path)` at its
                        // "Important #1" recheck above) rather than assuming DELETE always wiped
                        // the thumbnail (it does today, via `removeItem(at: thumbDir)` above, but
                        // pinning to the actual file-existence check keeps this correct even if
                        // that assumption ever changes, and correctly does NOT clear when the
                        // external thumbnail file is still present — the protected-no-op case).
                        let willFallBackToAuto = CoverSource.isExternal(dto.coverImageName)
                            && !FileManager.default.fileExists(
                                atPath: coverURL(bundleURL: lib.bundleURL, bookID: dto.id).path)
                        let regenOutcome = try? await Self.regenerateThumbnail(
                            bookID: dto.id, sourceURLPath: effectiveDTO.path,
                            preferredName: dto.coverImageName, bundleURL: lib.bundleURL, db: lib.db)
                        // `bookRow(from:)` reintroduced the crop the DTO carried, which was
                        // authored for the now-gone external image; left in place it would
                        // distort the auto (first-page) cover the fallback just wrote. Clear it
                        // only on that fallback — a preserved external cover, or a normal
                        // auto/manual regenerate/relink (both of which guard `!isExternal` before
                        // ever calling regenerateThumbnail), keeps its own legitimately-authored
                        // crop untouched.
                        //
                        // Codex review #4 (G21 followup): additionally require that regeneration
                        // actually WROTE the auto cover (`.wroteAuto`). If the source is gone /
                        // unreadable / unsupported, `regenerateThumbnail` throws (→ `try?` yields
                        // nil) or returns `.skippedExternal`, meaning no auto cover exists; clearing
                        // the crop then would discard the restored rectangle for nothing. Only clear
                        // when the fallback both was predicted AND produced a fresh auto cover.
                        if willFallBackToAuto, regenOutcome == .wroteAuto {
                            // Smoke H3 fix (G21 followup): the external image is unrecoverable and we
                            // wrote a plain auto (first-page) cover, so the row is auto now. Drop the
                            // @external sentinel too — otherwise coverImageName stays @external while
                            // the image is auto, leaving the book stuck (regenerate/relink disabled by
                            // the isExternal guard, "revert to auto" still offered). Mirror the local
                            // AppState.regenerateThumbnail fallback.
                            try? lib.db.updateBook(id: dto.id, patch: BookPatch(clearCoverImageName: true))
                            try? lib.db.updateBookCoverCropRect(id: dto.id, json: nil)
                        }
                    }
                } catch {
                    // id が既に別の本に再利用されている（restoreBook は plain INSERT なので
                    // UNIQUE 制約違反として届く）。この行はスキップし、他の行の復元は継続する
                    // （1 行の衝突でバッチ全体を失敗させない／別の本を上書きしない）。
                }
            }
            if restoredCount > 0 { self.notifyStructureChanged(lib.uuid) }
            // G16 A1: 実際に復元できた件数をクライアントへ返す（衝突でスキップされた行があると
            // restored < requested になり、UI が「取り消せませんでした」等を判断できる）。
            // G16 Codex Critical: restoredIDs も返す。クライアントは redo（再削除）をこの一覧に
            // 絞ることで、部分復元のとき「復元されなかった id」を巻き込んで再利用先の別の本を
            // 誤って消すのを防ぐ。
            return RestoreResultDTO(restored: restoredCount, requested: dtos.count, restoredIDs: restoredIDs)
        }
        // 4.2c-6b: 表紙候補（アーカイブのページ名一覧）。
        api.get("libraries/:lib/books/:id/cover-candidates") { request, context in
            let (_, row) = try await resolver.resolveBook(request, context)
            var entries: [String] = []
            if let path = row.path, let ex = ArchiveAdapter.coverExtractor(for: URL(fileURLWithPath: path)) {
                entries = (try? await ex.listImageEntries(in: URL(fileURLWithPath: path)))?.names ?? []
            }
            return CoverCandidatesDTO(entries: entries, current: row.coverImageName)
        }
        // 4.2c-6b: 選択ページ画像（クロップ編集プレビュー）。?name=<entry>&maxw=<px>。
        api.get("libraries/:lib/books/:id/entry-image") { [config] request, context in
            let (_, row) = try await resolver.resolveBook(request, context)
            guard let name = request.uri.queryParameters.get("name"),
                  let path = row.path,
                  let ex = ArchiveAdapter.coverExtractor(for: URL(fileURLWithPath: path)) else {
                throw HTTPError(.notFound)
            }
            guard var data = try? await ex.extractCoverImage(from: URL(fileURLWithPath: path), preferredName: name) else {
                throw HTTPError(.notFound)
            }
            let maxw = request.uri.queryParameters.get("maxw", as: Int.self)
            if let maxw, maxw > 0 { data = config.transcoder.scaled(data, maxWidth: maxw) }
            // fnv1aHash（ContentEndpoints.swift）を使う。String.hashValue はプロセスをまたいで
            // 安定しない per-process seed のため、再起動のたびに ETag が変わって 304 が壊れる
            // （最終レビュー Finding 3・bookETag と同じ理由）。
            let etag = bookETag(for: row) + "-entry-" + String(fnv1aHash(name), radix: 36)
            if request.headers[.ifNoneMatch] == etag { return Response(status: .notModified) }
            return cacheableImageResponse(data: data, etag: etag, request: request)
        }
        // 4.2c-6b: 表紙更新（RW）。coverImageName 更新時は thumbnail を再生成する。
        api.put("libraries/:lib/books/:id/cover") { [self] request, context in
            try context.requireEdit()
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: CoverUpdateRequest.self, context: context)
            if body.setCoverImageName {
                var patch = BookPatch()
                if let name = body.coverImageName { patch.coverImageName = name }
                else { patch.clearCoverImageName = true }
                try lib.db.updateBook(id: row.id, patch: patch)
                try await Self.regenerateThumbnail(
                    bookID: row.id, sourceURLPath: row.path, preferredName: body.coverImageName,
                    bundleURL: lib.bundleURL, db: lib.db)
            }
            if body.setCoverCropRect {
                try lib.db.updateBookCoverCropRect(id: row.id, json: body.coverCropRect)
            }
            self.notifyBookChanged(lib.uuid, row.id)
            let updated = (try? lib.db.fetchBook(id: row.id)) ?? row
            return makeBookDetailDTO(from: updated)
        }
        // G21 #5: 1 冊だけ表紙を今のファイルから作り直す（RW）。庫全体の再生成
        // （maintenance/compress-covers）は 12,000 冊規模で現実的でないため、単冊経路を用意する。
        // 外部表紙（手動アップロード）は上書きしない。アーカイブ内エントリを手動指定した本は
        // coverImageName を preferredName として尊重し、同じエントリから作り直す。
        api.post("libraries/:lib/books/:id/cover/regenerate") { [self] request, context in
            try context.requireEdit()
            let (lib, row) = try await resolver.resolveBook(request, context)
            guard !CoverSource.isExternal(row.coverImageName) else {
                // 外部表紙は再抽出対象外。現状を返して no-op とする（エラーにはしない）。
                return makeBookDetailDTO(from: row)
            }
            try await Self.regenerateThumbnail(
                bookID: row.id, sourceURLPath: row.path, preferredName: row.coverImageName,
                bundleURL: lib.bundleURL, db: lib.db)
            self.notifyBookChanged(lib.uuid, row.id)
            let updated = (try? lib.db.fetchBook(id: row.id)) ?? row
            return makeBookDetailDTO(from: updated)
        }
        // G4b: 外部画像を表紙に（RW）。画像バイトを thumbnail.jpg として保存＋coverImageName="@external"＋crop。
        api.put("libraries/:lib/books/:id/cover-image") { [self] request, context in
            try context.requireEdit()
            let (lib, row) = try await resolver.resolveBook(request, context)
            let imageData: Data
            do {
                let buffer = try await request.body.collect(upTo: 30 * 1024 * 1024)   // 上限 30MB
                imageData = Data(buffer: buffer)
            } catch is NIOTooManyBytesError {
                throw HTTPError(.contentTooLarge)   // 30MB 超 → 413
            }
            guard !imageData.isEmpty,
                  let src = CGImageSourceCreateWithData(imageData as CFData, nil),
                  CGImageSourceGetCount(src) > 0 else {
                throw HTTPError(.badRequest)
            }
            let resized = CoverImageResizer.resizeJPEG(imageData, maxPixelSize: 1200)
            let thumbURL = coverURL(bundleURL: lib.bundleURL, bookID: row.id)
            try FileManager.default.createDirectory(
                at: thumbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try resized.write(to: thumbURL, options: .atomic)
            var patch = BookPatch()
            patch.coverImageName = CoverSource.externalSentinel
            try lib.db.updateBook(id: row.id, patch: patch)
            // crop 未指定=解除（G4a の setExternalCover と同 atomicity＝新表紙に旧 crop を残さない）。
            try lib.db.updateBookCoverCropRect(id: row.id, json: request.uri.queryParameters.get("crop"))
            self.notifyBookChanged(lib.uuid, row.id)
            let updated = (try? lib.db.fetchBook(id: row.id)) ?? row
            return makeBookDetailDTO(from: updated)
        }
        // 4.2c-8: ラベルカスタマイズ取得（R 可）。未設定キーは空マップ。
        api.get("libraries/:lib/label-settings") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            func decodeMap(_ key: String) -> [String: String] {
                guard let json = (try? lib.db.getLibrarySetting(key: key)) ?? nil,
                      let data = json.data(using: .utf8),
                      let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
                return map
            }
            return LabelSettingsDTO(
                customFieldLabels: decodeMap("custom_field_labels"),
                customBookTypeLabels: decodeMap("custom_book_type_labels"))
        }
        // 4.2c-8: ラベルカスタマイズ保存（RW 必須）。キー名・JSON 形式はローカル LibrarySettings と同一。
        api.put("libraries/:lib/label-settings") { [self] request, context in
            try context.requireEdit()
            let lib = try await resolver.resolveLibrary(request, context)
            let body = try await request.decode(as: LabelSettingsDTO.self, context: context)
            func encodeMap(_ map: [String: String]) -> String {
                let cleaned = map.filter { !$0.value.isEmpty }
                let data = (try? JSONEncoder().encode(cleaned)) ?? Data("{}".utf8)
                return String(decoding: data, as: UTF8.self)
            }
            try lib.db.setLibrarySetting(key: "custom_field_labels", value: encodeMap(body.customFieldLabels))
            try lib.db.setLibrarySetting(key: "custom_book_type_labels", value: encodeMap(body.customBookTypeLabels))
            self.notifySettingsChanged(lib.uuid)
            return LabelSettingsDTO(
                customFieldLabels: body.customFieldLabels.filter { !$0.value.isEmpty },
                customBookTypeLabels: body.customBookTypeLabels.filter { !$0.value.isEmpty })
        }
        // A2: 監視フォルダ設定の取得（R 可）。G12b-2c: subfolderMode ＋ presets を同梱。
        api.get("libraries/:lib/watch-config") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            return try Self.buildWatchConfigDTO(lib: lib)
        }
        // A2: 監視フォルダ設定の更新（RW）。blind-replace ではなく id マージ:
        // 既存 id は baseline をサーバ保持・編集反映／新規 id はパス検証＋baseline スキャン／消えた id は削除。
        api.put("libraries/:lib/watch-config") { [self] request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let dto = try await request.decode(as: WatchConfigDTO.self, context: context)

            // 既存保管フォルダを id でマップ
            let existingJSON = (try? lib.db.getLibrarySetting(key: "watched_folders")) ?? nil
            let existing: [WatchedFolder] = existingJSON.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([WatchedFolder].self, from: $0) } ?? []
            let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

            var merged: [WatchedFolder] = []
            for f in dto.folders {
                let mode = WatchedFolder.SubfolderMode(rawValue: f.subfolderMode.rawValue) ?? .topLevelOnly
                if let prior = existingByID[f.id] {
                    // 既存: baseline はサーバ保持、編集フィールドを反映
                    merged.append(WatchedFolder(id: f.id, path: f.path, enabled: f.enabled,
                                                presetID: f.presetID, baseline: prior.baseline, subfolderMode: mode))
                } else {
                    // 新規: パス検証（実在＋ディレクトリ）
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir), isDir.boolValue else {
                        throw HTTPError(.badRequest, message: "監視フォルダのパスが無効です: \(f.path)")
                    }
                    // baseline = 現在の中身（既存スキップ）
                    let baseline = WatchFolderScanner.enumerateCandidates(
                        folder: URL(fileURLWithPath: f.path), mode: mode).map { $0.path }
                    merged.append(WatchedFolder(id: f.id, path: f.path, enabled: f.enabled,
                                                presetID: f.presetID, baseline: baseline, subfolderMode: mode))
                }
            }

            try lib.db.setLibrarySetting(key: "folder_watch_enabled", value: dto.enabled ? "true" : "false")
            let data = try JSONEncoder().encode(merged)
            try lib.db.setLibrarySetting(key: "watched_folders", value: String(decoding: data, as: UTF8.self))
            self.notifySettingsChanged(lib.uuid)
            return try Self.buildWatchConfigDTO(lib: lib)
        }
        // G12b-3a: 監視フォルダの今すぐスキャン（admin）。ホストの FolderWatcher を発火。
        api.post("libraries/:lib/watch/scan-now") { [self] request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            config.onScanNowRequested?(lib.uuid)
            return HTTPResponse.Status.noContent
        }
        // G12b-3c: 既存フォルダ一括再取込（admin）= 該当 folder の baseline をクリアして scan。
        // dedup が既取込済みファイルの再取込を防ぐため、baseline を空にしても実害はない。
        api.post("libraries/:lib/watch/import-existing") { [self] request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let req = try await request.decode(as: ImportExistingRequest.self, context: context)

            // 既存の watched_folders を読み、該当 id の baseline を [] にして保存（他 folder/フィールドは保持）。
            let existingJSON = (try? lib.db.getLibrarySetting(key: "watched_folders")) ?? nil
            var folders: [WatchedFolder] = existingJSON.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([WatchedFolder].self, from: $0) } ?? []
            guard let idx = folders.firstIndex(where: { $0.id == req.folderID }) else { throw HTTPError(.notFound) }
            folders[idx].baseline = []
            let data = try JSONEncoder().encode(folders)
            try lib.db.setLibrarySetting(key: "watched_folders", value: String(decoding: data, as: UTF8.self))
            self.notifySettingsChanged(lib.uuid)  // ホストが reloadWatchedFolders + reloadFolderWatcher
            self.config.onScanNowRequested?(lib.uuid)  // G12b-3a と同じ scan 発火経路
            return HTTPResponse.Status.noContent
        }
        // A2: ライブラリロック設定（admin）。パスワードを salt+hash で DB に保存。
        // G27a Task6: 既存ロックがある場合は変更にも現パスワードを要求する（解除と同じ扱いに揃える）。
        // 以前は変更が無検証だったため、解錠済みの端末を離席中に第三者がパスワードを上書きし
        // 所有権を奪えた（GUI の解除は元々パスワード必須だったのに対する非対称の脆弱性）。
        // G27a task 8 (Codex High #1・TOCTOU): 以前は「検証してから無条件で書く」の 2 段が
        // 分離しており、①攻撃者が旧パスワードで検証を通す → ②正規利用者が先に変更 →
        // ③攻撃者の書き込みが後から着地して正規の変更を上書き、という compare-and-set 抜けの
        // 窓があった。今は `verifiedCredential(for:)` が返す**照合した credential 世代**
        // （遅延 PBKDF2 移行が起きていればその移行後の hash）を条件にした DB 側 compare-and-set
        // （`Database.compareAndSetLibrarySettings`）へ書き込みを委ねる。移行後の hash を条件に
        // 使うのは、移行自体が「この検証を起こした本人」による正当な値更新であり、移行前の hash を
        // 条件にすると移行直後の書き込みが毎回「他者に変更された」と誤判定されてしまうため。
        api.post("libraries/:lib/lock") { [self] request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let body = try await request.decode(as: LockRequest.self, context: context)
            guard !body.password.isEmpty else { throw HTTPError(.badRequest) }
            // 既存ロックの有無は都度ライブから読む（resolver の isLocked スナップショットではなく、
            // このリクエスト内で最新の DB 値を見る）。
            let expectedHash: String?
            if lib.currentLockCredential() != nil {
                // 認証(admin bearer token)は通っているが、ロック自体の所有権証明（現パスワード）が
                // 無い/誤っている → 403（401 ではない）。比較は LibraryLock.verifiedCredential 経由
                // （constant-time 比較・旧形式からの遅延移行を再利用し、自前比較を書かない）。
                guard let currentPassword = body.currentPassword, !currentPassword.isEmpty,
                      let verified = lib.verifiedCredential(for: currentPassword) else {
                    throw HTTPError(.forbidden)
                }
                expectedHash = verified
            } else {
                // 新規施錠: 「hash キーがまだ存在しない」ことを条件にする
                // （二重の同時「新規施錠」の race 防止）。
                expectedHash = nil
            }
            let salt = LibraryLock.generateSalt()
            let hash = LibraryLock.computeHash(password: body.password, saltHex: salt)
            // G25c: salt と hash は**組で意味を持つ**ため単一トランザクションで書く。
            // 別々に書くと同時実行や外部変更と交錯して `salt B + hash A` が残り、
            // どのパスワードでも解錠できない庫になりうる。
            let applied = try lib.db.compareAndSetLibrarySettings(
                conditionKey: "lock_password_hash", expectedValue: expectedHash,
                newValues: ["lock_password_salt": salt, "lock_password_hash": hash])
            guard applied else {
                // 検証に使った資格情報（または「未施錠」という前提）が既に古い。DB は未変更。
                throw HTTPError(.conflict)
            }
            self.notifySettingsChanged(lib.uuid)
            return HTTPResponse.Status.noContent
        }
        // A2: ライブラリロック解除（admin）。hash と salt を削除。
        // G27a Task6: 既存ロックがあれば現パスワード必須（POST 変更と同じ規則）。DELETE のボディで
        // 受け取る（body 付き DELETE は本ファイルの shelves/:id/books で既に使っている作法）。
        // ロックが無ければボディ自体を省略でき、後方互換（旧クライアントの無ボディ DELETE）を壊さない。
        // G27a task 8: 同上、compare-and-set に載せ替え（TOCTOU を閉じる）。
        api.delete("libraries/:lib/lock") { [self] request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            guard lib.currentLockCredential() != nil else {
                // ロックが無い: 消す物が無いので no-op 成功（旧クライアントの無ボディ DELETE と互換）。
                self.notifySettingsChanged(lib.uuid)
                return HTTPResponse.Status.noContent
            }
            let currentPassword = try await Self.decodeOptionalLockRemoveBody(request, context: context)
            guard let currentPassword, !currentPassword.isEmpty,
                  let verified = lib.verifiedCredential(for: currentPassword) else {
                throw HTTPError(.forbidden)
            }
            // G25c: 解除も組でまとめて消す（片方だけ残る中間状態を作らない）。
            let applied = try lib.db.compareAndDeleteLibrarySettings(
                conditionKey: "lock_password_hash", expectedValue: verified,
                keysToDelete: ["lock_password_hash", "lock_password_salt"])
            guard applied else {
                // 検証に使った資格情報が既に古い（他者が同時に変更/解除した）。DB は未変更。
                throw HTTPError(.conflict)
            }
            self.notifySettingsChanged(lib.uuid)
            return HTTPResponse.Status.noContent
        }
        // A2: per-library 取り込み設定の取得（R 可）。未設定キーは nil（= グローバル既定に委譲）。
        api.get("libraries/:lib/import-config") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            let ac = ((try? lib.db.getLibrarySetting(key: ImportDefaults.libAutoClassifyKey)) ?? nil).map { $0 == "1" || $0 == "true" }
            let th = ((try? lib.db.getLibrarySetting(key: ImportDefaults.libThickThresholdKey)) ?? nil).flatMap { Int($0) }
            return ImportConfigDTO(autoClassifyEnabled: ac, thickBookThreshold: th)
        }
        // A2: per-library 取り込み設定の更新（RW）。nil 指定は override 削除（= グローバル既定へ戻す）。
        api.put("libraries/:lib/import-config") { [self] request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let dto = try await request.decode(as: ImportConfigDTO.self, context: context)
            if let ac = dto.autoClassifyEnabled { try lib.db.setLibrarySetting(key: ImportDefaults.libAutoClassifyKey, value: ac ? "true" : "false") } else { try lib.db.deleteLibrarySetting(key: ImportDefaults.libAutoClassifyKey) }
            if let th = dto.thickBookThreshold { try lib.db.setLibrarySetting(key: ImportDefaults.libThickThresholdKey, value: String(max(5, min(100, th)))) } else { try lib.db.deleteLibrarySetting(key: ImportDefaults.libThickThresholdKey) }
            self.notifySettingsChanged(lib.uuid)
            return dto
        }
        // G12b-3a: 一般設定の取得（R 可）。
        api.get("libraries/:lib/general-settings") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            let nameRaw: String? = (try? lib.db.getLibrarySetting(key: "display_name")) ?? nil
            let name: String = nameRaw ?? ""
            let enabledRaw: String? = (try? lib.db.getLibrarySetting(key: "backup_enabled")) ?? nil
            // 既定は true（LibrarySettings.defaultBackupEnabled と一致）。キー未設定の legacy
            // ライブラリで false を返すと、admin が一般タブを保存した際にバックアップが静かに
            // 無効化されるため（Codex review Important #1）。
            let enabled: Bool = enabledRaw.map { $0 == "1" || $0 == "true" } ?? true
            let gensRaw: String? = (try? lib.db.getLibrarySetting(key: "backup_generations")) ?? nil
            let gens: Int = gensRaw.flatMap { Int($0) } ?? 5
            return GeneralSettingsDTO(displayName: name, backupEnabled: enabled, backupGenerations: gens)
        }
        // G12b-3a: 一般設定の更新（admin）。
        api.put("libraries/:lib/general-settings") { [self] request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let dto = try await request.decode(as: GeneralSettingsDTO.self, context: context)
            let clampedGens = max(1, min(20, dto.backupGenerations))
            try lib.db.setLibrarySetting(key: "display_name", value: dto.displayName)
            try lib.db.setLibrarySetting(key: "backup_enabled", value: dto.backupEnabled ? "true" : "false")
            try lib.db.setLibrarySetting(key: "backup_generations", value: String(clampedGens))
            self.notifySettingsChanged(lib.uuid)
            // クランプ後の値をエコーして GET と一致させる（Codex review Minor）。
            return GeneralSettingsDTO(displayName: dto.displayName, backupEnabled: dto.backupEnabled, backupGenerations: clampedGens)
        }
        // G12b-3c: 命名プリセット集合の取得（R 可）。
        api.get("libraries/:lib/presets") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            let raw: String? = (try? lib.db.getLibrarySetting(key: "filename_format_presets")) ?? nil
            let defID: String = ((try? lib.db.getLibrarySetting(key: "filename_format_default_id")) ?? nil) ?? ""
            var presets: [FilenameFormatPreset] = []
            if let raw, let data = raw.data(using: .utf8) { presets = (try? JSONDecoder().decode([FilenameFormatPreset].self, from: data)) ?? [] }
            if presets.isEmpty {
                // 空/未設定はローカル既定の単一プリセット相当にフォールバック。
                let fmt = ((try? lib.db.getLibrarySetting(key: "filename_format")) ?? nil) ?? "(@genre) [@keywordB] [@author] @title"
                presets = [FilenameFormatPreset(id: "default", name: "既定", format: fmt)]
            }
            let dto = PresetSetDTO(presets: presets.map { FilenameFormatPresetDTO(id: $0.id, name: $0.name, format: $0.format) },
                                   defaultID: FilenameFormatPresetLogic.validatedDefaultID(presets: presets, requested: defID))
            return dto
        }
        // G12b-3c: 命名プリセット集合の更新（admin）。空配列は 400。
        api.put("libraries/:lib/presets") { [self] request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let dto = try await request.decode(as: PresetSetDTO.self, context: context)
            // Codex review (G12b-3c): format が nil/空文字（空白のみ含む）のプリセットを許すと、
            // 共有 DB キー filename_format_presets に "" が永続化され、ローカル側の読み取りも壊れる。
            // 1 件でも無効なら 400 でリクエスト全体を拒否する（部分保存はしない）。
            guard dto.presets.allSatisfy({ !($0.format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw HTTPError(.badRequest, message: "各プリセットに format が必要です")
            }
            let presets = dto.presets.map { FilenameFormatPreset(id: $0.id, name: $0.name, format: $0.format ?? "") }
            guard !presets.isEmpty else { throw HTTPError(.badRequest, message: "プリセットは最低 1 個必要です") }
            let validDefault = FilenameFormatPresetLogic.validatedDefaultID(presets: presets, requested: dto.defaultID)
            let encoded = String(decoding: try JSONEncoder().encode(presets), as: UTF8.self)
            try lib.db.setLibrarySetting(key: "filename_format_presets", value: encoded)
            try lib.db.setLibrarySetting(key: "filename_format_default_id", value: validDefault)
            self.notifySettingsChanged(lib.uuid)
            return PresetSetDTO(presets: presets.map { FilenameFormatPresetDTO(id: $0.id, name: $0.name, format: $0.format) }, defaultID: validDefault)
        }
        // G12b-3a: 整合性チェック（admin・非破壊）。
        api.get("libraries/:lib/integrity-check") { request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let rows = (try? lib.db.integrityCheck()) ?? ["(エラー)"]
            return IntegrityCheckDTO(healthy: rows == ["ok"], rows: rows)
        }
        // G12b-3a: 今すぐバックアップ（admin）。同一 lib.db から作成し世代 prune。
        api.post("libraries/:lib/backup-now") { request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let gens = ((try? lib.db.getLibrarySetting(key: "backup_generations")) ?? nil).flatMap { Int($0) } ?? 5
            _ = try BackupManager.makeBackup(from: lib.db, bundleURL: lib.bundleURL, timestamp: BackupManager.timestampNow())
            do {
                try BackupManager.prune(in: BackupManager.backupsDir(for: lib.bundleURL), keep: gens)
            } catch {
                Self.backupLogger.warning("backup prune failed for \(lib.uuid, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return HTTPResponse.Status.noContent
        }
        // G12b-3b: メタ補完（admin・非同期ジョブ）。
        api.post("libraries/:lib/maintenance/complete-metadata") { request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let started = await self.maintenanceRegistry.start(library: lib.uuid, job: "complete-metadata") { progress, isCancelled in
                try await MetadataCompletion.fillMissingSeriesVolume(
                    in: lib.db,
                    progress: { d, t in progress(d, t) },
                    isCancelled: { await isCancelled() }
                )
            }
            return started ? HTTPResponse.Status.accepted : HTTPResponse.Status.conflict
        }
        // G12b-3b: 表紙圧縮（admin・非同期ジョブ）。
        api.post("libraries/:lib/maintenance/compress-covers") { request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let started = await self.maintenanceRegistry.start(library: lib.uuid, job: "compress-covers") { progress, isCancelled in
                try await CoverCompression.compressOversizedCovers(
                    db: lib.db, bundleURL: lib.bundleURL,
                    progress: { d, t in progress(d, t) },
                    isCancelled: { await isCancelled() }
                )
            }
            return started ? HTTPResponse.Status.accepted : HTTPResponse.Status.conflict
        }
        // G12b-3b: 実行中メンテナンスの中断（admin・実行中ジョブが無ければ no-op）。
        api.post("libraries/:lib/maintenance/cancel") { request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            await self.maintenanceRegistry.cancel(library: lib.uuid)
            return HTTPResponse.Status.noContent
        }
        // G27b: メンテナンス進捗の問い合わせ（隣接する maintenance ルートと同じ admin 権限）。
        // 31 時間規模のフルスキャンを CLI から SSE を張らずに確認できるようにする。
        api.get("libraries/:lib/maintenance/status") { request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            guard let status = await self.maintenanceRegistry.status(library: lib.uuid) else {
                return MaintenanceStatusReply(running: false)
            }
            return MaintenanceStatusReply(
                running: true, job: status.job, done: status.done, total: status.total,
                startedAt: Int64(status.startedAt.timeIntervalSince1970))
        }
        // G27b Task5: フル CRC スキャン（31 時間規模）を非同期ジョブとして起動する。
        // complete-metadata/compress-covers と同じ形（同じ maintenanceRegistry・同じ admin 権限・
        // 202/409 の使い分け）を踏襲する ―― ここだけ別のジョブ機構やロールを発明しない。
        // 進捗・中断は既存の GET maintenance/status・POST maintenance/cancel をそのまま使う
        // （full-scan 専用の状態確認/中断エンドポイントは追加しない）。
        api.post("libraries/:lib/integrity/full-scan") { request, context in
            try context.requireAdmin()
            let lib = try await resolver.resolveLibrary(request, context)
            let dto = try await request.decode(as: FullScanStartRequest.self, context: context)
            let mode = try Self.parseFullScanMode(dto.mode)
            let started = await self.maintenanceRegistry.start(library: lib.uuid, job: "full-scan") { progress, isCancelled in
                // `isCancelled` は registry の run クロージャ引数として非 escaping で渡ってくるが、
                // FullIntegrityScanner.scan の isCancelled は @escaping（内部で保持しつつ冊単位・
                // エントリ単位の両方で繰り返し呼ぶため）。ここで scan を呼び終えるまでの間しか
                // 実際には使わない（scan が return する前に呼び出しは終わる）ので、
                // withoutActuallyEscaping で安全にブリッジする。
                try await withoutActuallyEscaping(isCancelled) { escapableIsCancelled in
                    let report = try await FullIntegrityScanner.scan(
                        database: lib.db, mode: mode,
                        deps: FullIntegrityScanner.liveDependencies(libraryBundleURL: lib.bundleURL),
                        progress: { d, t in progress(d, t) },
                        isCancelled: escapableIsCancelled)
                    return report.scanned
                }
            }
            return started ? HTTPResponse.Status.accepted : HTTPResponse.Status.conflict
        }
        // G14: リモートサイドバーの安定件数（ライブラリ総数・最近件数）。scope 非依存。read で可。
        api.get("libraries/:lib/counts") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            let recentDays = ((try? lib.db.getLibrarySetting(key: "recent_days")) ?? nil).flatMap { Int($0) } ?? 14
            let libraryTotal = (try? lib.db.fetchBookCount()) ?? 0
            let recentCount = (try? lib.db.fetchRecentBookCount(days: recentDays)) ?? 0
            return LibraryCountsDTO(libraryTotal: libraryTotal, recentCount: recentCount, recentDays: recentDays)
        }
        // A2: グローバル取り込み既定の取得（庫非依存・R 可）。サーバ canonical（UserDefaults）。
        api.get("import-config") { _, _ in
            GlobalImportConfigDTO(autoClassifyEnabled: ImportDefaults.globalAutoClassify(), thickBookThreshold: ImportDefaults.globalThickThreshold())
        }
        // A2: グローバル取り込み既定の更新（庫非依存・admin）。
        api.put("import-config") { request, context in
            try context.requireAdmin()
            let dto = try await request.decode(as: GlobalImportConfigDTO.self, context: context)
            ImportDefaults.setGlobalAutoClassify(dto.autoClassifyEnabled)
            ImportDefaults.setGlobalThickThreshold(dto.thickBookThreshold)
            return GlobalImportConfigDTO(autoClassifyEnabled: ImportDefaults.globalAutoClassify(), thickBookThreshold: ImportDefaults.globalThickThreshold())
        }
        // A2: 本のパス再リンク（RW）。relinkBook で path 更新＋ハッシュ NULL 化。
        api.post("libraries/:lib/books/:id/relink") { [self] request, context in
            try context.requireEdit()
            let bookID = try context.parameters.require("id", as: Int.self)
            let lib = try await resolver.resolveLibrary(request, context)
            guard ((try? lib.db.fetchBook(id: bookID)) ?? nil) != nil else { throw HTTPError(.notFound) }
            let body = try await request.decode(as: RelinkRequest.self, context: context)
            guard !body.newPath.isEmpty else { throw HTTPError(.badRequest) }
            // セキュリティ修正: newPath を許可ルート（バンドル配下／監視フォルダ／現存する他本の
            // ディレクトリ）で検証する。無検証だと edit tier のクライアントが任意のホストパスへ
            // relink し、続けて GET .../file（read tier）で中身を読み出せてしまう
            // （Arbitrary File Read via relink→file）。restore ハンドラと同じ検証ヘルパを使う。
            let roots = allowedRestoreRoots(lib: lib)
            guard isPathWithinAllowedRoots(body.newPath, roots: roots) else {
                throw HTTPError(.forbidden)
            }
            try lib.db.relinkBook(id: bookID, newPath: body.newPath)
            // G21 #5: relink はファイルが別物になったということなので、自動表紙は作り直し、
            // ページ数も新しいファイルの実数に更新する（smoke A10: 表紙とページ数だけ旧のまま問題）。
            // 手動指定・外部表紙は温存する。失敗しても relink 自体は成功扱いにする。
            if let updatedRow = (try? lib.db.fetchBook(id: bookID)) ?? nil {
                if !CoverSource.isExternal(updatedRow.coverImageName) {
                    _ = try? await Self.regenerateThumbnail(
                        bookID: updatedRow.id, sourceURLPath: updatedRow.path,
                        preferredName: updatedRow.coverImageName, bundleURL: lib.bundleURL, db: lib.db)
                }
                // G26 Codex Important #2: relink 先が破損していると `pageCount` は打ち切り値
                // （40 ページ本を差し替えたつもりで 13）になる。relink は**まさに**ユーザーが
                // 差し替え先を指し示す操作なので、ここを素通ししたら「壊れた読みから出た数値は
                // 記録しない」という規則が最も要る場所で破れる。ビューア/取込経路と同じ
                // `TruncatedReadPolicy.pageCountToWrite` を通す（nil＝書かない。修復後に
                // 次回オープンの収束処理が正しい値を入れる）。
                if let content = try? BookContentFactory.make(for: updatedRow),
                   let n = try? await content.pageCount,
                   let pages = TruncatedReadPolicy.pageCountToWrite(
                       livePageCount: n, truncated: await content.damageNote != nil) {
                    try? lib.db.updateBookPages(id: updatedRow.id, newPages: pages)
                }
            }
            self.notifyStructureChanged(lib.uuid)
            return HTTPResponse.Status.noContent
        }
        // A2: 重複スキャン（RW・content_hash を計算/キャッシュしグループ返却）。
        api.post("libraries/:lib/duplicates/scan") { request, context in
            try context.requireEdit()
            let lib = try await resolver.resolveLibrary(request, context)
            let books = (try? lib.db.fetchAllBooks()) ?? []
            let fm = FileManager.default
            var sizes: [(id: Int, size: Int64)] = []
            var meta: [Int: (url: URL, size: Int64, mtime: Double)] = [:]
            var missingCount = 0
            for b in books {
                guard let p = b.path else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir) else { missingCount += 1; continue }
                if isDir.boolValue { continue }
                let attrs = try? fm.attributesOfItem(atPath: p)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                sizes.append((b.id, size)); meta[b.id] = (URL(fileURLWithPath: p), size, mtime)
            }
            let candidateCount = sizes.count
            let need = DuplicateFinder.idsNeedingHash(sizes: sizes)
            let byID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
            var toHash: [Int] = []
            for id in need {
                guard let m = meta[id], let b = byID[id] else { continue }
                if let h = b.contentHash, !h.isEmpty, b.fileSize == m.size, b.fileMtime == m.mtime { continue }
                toHash.append(id)
            }
            var hashedCount = 0
            for id in toHash {
                guard let m = meta[id] else { continue }
                if let hash = try? ContentHasher.sha256(ofFileAt: m.url) {
                    try? lib.db.updateBookContentHash(id: id, hash: hash, size: m.size, mtime: m.mtime)
                    hashedCount += 1
                }
            }
            let fresh = (try? lib.db.fetchAllBooks()) ?? books
            let g = DuplicateFinder.groups(fresh, ignoring: [])
            func toDTO(_ groups: [DuplicateGroup]) -> [DuplicateGroupDTO] {
                groups.map { grp in
                    DuplicateGroupDTO(kind: grp.kind == .exact ? "exact" : "possibleSeriesVolume",
                                      key: grp.key, members: grp.members.map { makeBookListItemDTO(from: $0) })
                }
            }
            return DuplicateScanReply(exact: toDTO(g.exact), possible: toDTO(g.possible),
                                      candidateCount: candidateCount, hashedCount: hashedCount, missingCount: missingCount)
        }
        // 整合性検査（G27a）。結果は book_integrity に永続化されるので、
        // summary / list は再スキャンなしで何度でも呼べる。
        api.get("libraries/:lib/integrity/summary") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            let s = try lib.db.integritySummary()
            return IntegritySummaryReply(checked: s.checked, unchecked: s.unchecked,
                                         damaged: s.damaged, degraded: s.degraded)
        }

        api.get("libraries/:lib/integrity/list") { request, context in
            let lib = try await resolver.resolveLibrary(request, context)
            let raw = request.uri.queryParameters.get("status") ?? "damaged"
            guard let status = IntegrityStatus(rawValue: raw) else {
                throw HTTPError(.badRequest, message: "unknown integrity status: \(raw)")
            }
            let items = try lib.db.integrityRecords(status: status).map { book, rec in
                // Critical fix: path をそのまま返すとディレクトリ構成が read tier トークンにも
                // 漏れる（このエンドポイントは requireEdit していない）。他の場所と同じ redaction
                // 規約（DTOs.swift の path 秘匿コメント参照）に合わせ、basename だけを返す。
                IntegrityItemDTO(bookID: book.id, title: book.title,
                                 filename: book.path.map { ($0 as NSString).lastPathComponent },
                                 status: rec.status.rawValue, checkedAt: rec.checkedAt,
                                 entryCount: rec.entryCount, badEntries: rec.badEntries,
                                 degraded: rec.isDegraded)
            }
            return IntegrityListReply(items: items)
        }

        api.post("libraries/:lib/integrity/scan") { [self] request, context in
            try context.requireEdit()
            let lib = try await resolver.resolveLibrary(request, context)
            let report = try await QuickIntegrityScanner.scan(
                database: lib.db,
                deps: QuickIntegrityScanner.liveDependencies(
                    archiveExtractor: LibarchiveCoverExtractor(),
                    folderExtractor: FolderCoverExtractor()))
            // Important fix: 他の ~20 個の変更系ルートと違い、この経路だけ通知が無く、
            // book.pages/file_size を書いても開いている GUI ウィンドウ・SSE クライアントは
            // 再読込するまで空欄のまま残っていた。ページ数はメタデータ単位の変更ではなく
            // 候補全体（最大で「pages 未取得」の本すべて）への一括書き込みなので、
            // stamp 一括適用（1 冊ずつ notifyBookChanged）ではなく、既存行を一括で入れ替える
            // 一括操作（books 一括追加 / restore 等）と同じ構造レベルの notifyStructureChanged
            // を選ぶ（永続化に 1 件でも成功していれば通知する）。
            if report.scanned > report.persistenceFailures {
                notifyStructureChanged(lib.uuid)
            }
            return IntegrityScanReply(
                scanned: report.scanned,
                ok: report.byStatus[.ok] ?? 0,
                damaged: report.byStatus[.damaged] ?? 0,
                empty: report.byStatus[.empty] ?? 0,
                missing: report.byStatus[.missing] ?? 0,
                unsupported: report.byStatus[.unsupported] ?? 0,
                pagesUpdated: report.pagesUpdated,
                persistenceFailures: report.persistenceFailures)
        }

        // 同一シリーズの隣接巻（次/前）。サーバは全カタログを持つので未 DL でも真の隣接巻を返す。
        // 該当なしは book == nil（常に 200）。
        api.get("libraries/:lib/books/:id/adjacent") { request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let dir = request.uri.queryParameters.get("dir") ?? ""
            let sibling: BookRow?
            switch dir {
            case "next": sibling = try lib.db.nextVolumeInSeries(after: row)
            case "prev": sibling = try lib.db.prevVolumeInSeries(before: row)
            default: throw HTTPError(.badRequest)
            }
            let dto = sibling.map { s in
                makeBookListItemDTO(from: s)
                    .withLastPage((try? lib.db.loadViewerState(bookID: s.id))?.lastPage)
            }
            return AdjacentVolumeReply(book: dto)
        }
        // 表紙画像（ETag + immutable キャッシュ・If-None-Match で 304）。
        // ETag は表紙ファイル自身の mtime+size 由来（表紙差し替えを追跡 — 引き継ぎ(1)）。
        // 304 判定は Data(contentsOf:) の前に行う（一致時はバイト読込を省く — 4.1a Minor 解消）。
        // ?maxw= が指定された場合は ETag に幅を織り込み、縮小バイトを返す（4.1c）。
        api.get("libraries/:lib/books/:id/cover") { [config] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let url = coverURL(bundleURL: lib.bundleURL, bookID: row.id)
            let baseETag = thumbnailETag(url: url, bookID: row.id) ?? bookETag(for: row)
            let maxw = request.uri.queryParameters.get("maxw", as: Int.self)
            let etag = maxwETag(baseETag, maxw: maxw)
            if request.headers[.ifNoneMatch] == etag { return Response(status: .notModified) }
            guard var data = try? Data(contentsOf: url) else { throw HTTPError(.notFound) }
            if let maxw, maxw > 0 { data = config.transcoder.scaled(data, maxWidth: maxw) }
            // Finding 1: books.js の coverURL は `?v=<coverVersion>` に thumbnailETag（クォート除去済み）
            // を載せる。それが現在の baseETag（クォート除去後）と食い違うのは、relink/表紙差し替え後
            // クライアントがまだ古い版の URL を持っている状態 — immutable で焼き付けず no-store にする。
            // v が無い（旧クライアント）ときは today 通り常に immutable。
            // review follow-up Finding 1: native cover 取得はそもそも ?v= を送らないため
            // ここは常に cacheable=true（native 側の追加対応は不要）。web の表紙は <img src>
            // 経由でブラウザ HTTP キャッシュのみに依存する（IndexedDB 等アプリ内キャッシュを
            // 持たない）ため、no-store は HTTP キャッシュに対してのみ効けばよい。
            let requestedVersion = request.uri.queryParameters.get("v")
            let cacheable = requestedVersion == nil || requestedVersion == stripETagQuotes(baseETag)
            return cacheableImageResponse(data: data, etag: etag, request: request, cacheable: cacheable)
        }
        // 本のマニフェスト（ページ数・方向・形式・ETag・ページ単位 override）。
        // direction は実効方向（本ごと override があればその値、なければ config.defaultPageDirection）を
        // 常に返す。null を返さないことで Web リーダーがアプリ設定と同じ既定方向で開く（4.1c）。
        // pageOverrides（G17 T6b）: book_page_layout の全行を page_index(String)→mode で返す。
        // 1 件も無ければ nil（旧クライアント互換・ペイロード節約）。
        // pageCount は pages/:n と同じ BookContentCache から取る（BookContentFactory.make を毎回
        // 呼ぶと常に「今の実ファイル」を見るため、キャッシュ済みの古い FolderBookContent を
        // 返す pages/:n と食い違い、manifest が advertise した末尾ページが 404 になる回帰があった。
        // 実機 smoke で id=19 のフォルダブックにて再現・詳細は effectiveFileStat のコメント参照）。
        let contentCache = self.contentCache
        api.get("libraries/:lib/books/:id/manifest") { [config] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            // Finding 2: content と etag を同じ 1 回の effectiveFileStat 呼び出しから得る
            // （content(for:) の後で独立に bookETag(for: row) を呼び直すと、フォルダ本では
            // その間にディレクトリが変化しうるため、advertise する版と実際の pageCount が
            // 食い違う可能性があった）。
            let (content, etag) = try await contentCache.contentAndETag(for: row, libraryUUID: lib.uuid)
            let pageCount = try await content.pageCount
            let overrides = (try? lib.db.loadViewerState(bookID: row.id))?.overrides ?? [:]
            let pageOverrides: [String: Int]? = overrides.isEmpty
                ? nil
                : Dictionary(uniqueKeysWithValues: overrides.map { (String($0.key), $0.value) })
            return ManifestDTO(
                pageCount: pageCount,
                direction: directionString(row.pageDirection ?? config.defaultPageDirection),
                format: formatString(BookCategory.classify(path: row.path ?? "")),
                etag: etag,
                pageOverrides: pageOverrides,
                damageNote: await content.damageNote
            )
        }
        // ページ画像（ハンドルキャッシュ経由・ETag + immutable）。
        // 範囲外 → 404 / 範囲内の描画失敗 → 500（BookContentError.renderFailed 分離・4.1a）。
        // ?maxw= が指定された場合は ETag に幅を織り込み、縮小バイトを返す（4.1c）。
        api.get("libraries/:lib/books/:id/pages/:n") { [config] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let n = try context.parameters.require("n", as: Int.self)
            // Finding 2: manifest と同じ理由で、content と book 版 ETag を同じ 1 回の stat から得る。
            let (content, bookVersion) = try await contentCache.contentAndETag(for: row, libraryUUID: lib.uuid)
            let maxw = request.uri.queryParameters.get("maxw", as: Int.self)
            let etag = maxwETag(bookVersion + "-p\(n)", maxw: maxw)
            if request.headers[.ifNoneMatch] == etag { return Response(status: .notModified) }
            do {
                var data = try await content.imageData(at: n)
                if let maxw, maxw > 0 { data = config.transcoder.scaled(data, maxWidth: maxw) }
                // Finding 1: reader.js/RemoteBookContent が付ける `?v=` は manifest.etag を
                // normalizeVersion した値（book レベル・-pN や maxw は含まない）。bookVersion は
                // まさにその形（クォート付き）なので、比較は stripETagQuotes で正規化して行う。
                // 食い違えば（relink 直後に古い版の URL がまだ使われている等）immutable で
                // 焼き付けず no-store にする。v が無ければ today 通り常に immutable。
                // review follow-up Finding 1: この no-store は HTTP キャッシュ層を無効化する
                // だけなので、ページ画像は web 側 prefetch.js（fetchPageBlob の cache-control
                // 判定→putPage スキップ）・native 側 RemoteBookContent.imageData
                // （RemoteLibraryClient.pageData の no-store 判定→RemotePageCache への
                // store スキップ）がそれぞれ IndexedDB/RemotePageCache への永続化を止める。
                let requestedVersion = request.uri.queryParameters.get("v")
                let cacheable = requestedVersion == nil || requestedVersion == stripETagQuotes(bookVersion)
                return cacheableImageResponse(data: data, etag: etag, request: request, cacheable: cacheable)
            } catch let e as BookContentError {
                switch e {
                case .pageOutOfRange: throw HTTPError(.notFound)
                case .renderFailed: throw HTTPError(.internalServerError)
                default: throw HTTPError(.notFound)
                }
            }
        }
        // 閲覧進行状況の書き込み（last_page）＋ mark-as-read（Mac ビューアとパリティ: unseen=false /
        // play_date=now）。本を mutate するので最後に onBookChanged を発火し Mac UI / 将来のクライアントへ
        // 即時反映させる（4.2a）。viewer フラグ（spread/coverOffset）は触らない。
        //
        // G26 Codex Important #1: 破損アーカイブは「壊れた位置まで読める本」として開くため、
        // Web リーダーの `startUi = min(pageCount, p)` が保存済み位置（例 150）を打ち切り
        // ページ数（例 30）の末尾へクランプし、その 29 をここへ POST してくる。素直に書くと
        // ネイティブ側で `TruncatedReadPolicy` を作る原因になった事故（読書位置の破壊）が
        // そのまま再現する。**クライアントの自己抑制には頼れない**（旧クライアントが居るし、
        // 判定材料の damageNote を持たないクライアントもある）ので、判定はサーバで行う。
        //
        // `restart`（optional・省略＝false）は「ユーザーが明示的に『最初から』を選んだ」という
        // 意思表示。ネイティブの resume シートが `storedLastPage = 0` に落として意思を通すのと
        // 同じことを、保護下限を 0 にすることで行う。**page == 0 からは推測しない** —
        // page 0 は単に 1 ページ目でもあるため、破損本の 1 ページ目を表示しただけで
        // 保存位置が消える（Codex の指摘どおり）。旧クライアントはキーを送らないので
        // 従来どおり保護される（保護しすぎる側に倒れるので安全）。
        api.post("libraries/:lib/books/:id/progress") { [config, contentCache] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: ProgressRequestBody.self, context: context)
            guard body.page >= 0 else { throw HTTPError(.badRequest) }
            let storedLastPage = (body.restart == true)
                ? 0
                : ((try? lib.db.loadViewerState(bookID: row.id))?.lastPage ?? 0)
            // 前進書き込み（大多数）では打ち切りか否かで結果が変わらない。破損判定は
            // アーカイブ全走査を伴いうるので、結果に効く場合だけ払う（判断自体は policy 側）。
            var truncated = false
            if TruncatedReadPolicy.truncationAffectsLastPage(
                currentPage: body.page, storedLastPage: storedLastPage) {
                if let content = try? await contentCache.content(for: row, libraryUUID: lib.uuid) {
                    truncated = await content.damageNote != nil
                } else {
                    // 中身を開けない（ファイル欠損等）＝打ち切りかどうか確かめられない。
                    // 保存位置を壊す側ではなく守る側へ倒す。
                    truncated = true
                }
            }
            let page = TruncatedReadPolicy.lastPageToPersist(
                currentPage: body.page, storedLastPage: storedLastPage, truncated: truncated)
            try lib.db.updateLastPage(bookID: row.id, lastPage: page)
            try lib.db.markAsRead(bookID: row.id, at: Date())
            config.onBookChanged?(lib.uuid, row.id)
            return HTTPResponse.Status.ok
        }
        // ページ方向の書き戻し（Web リーダーでの変更を本ごと DB に反映・4.1c F2b）。
        api.post("libraries/:lib/books/:id/direction") { [self] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: DirectionRequestBody.self, context: context)
            let dir: PageDirection?
            switch body.direction {
            case "rtl": dir = .rightToLeft
            case "ltr": dir = .leftToRight
            case nil, "": dir = nil
            default: throw HTTPError(.badRequest)
            }
            try lib.db.updatePageDirection(bookID: row.id, direction: dir)
            self.notifyBookChanged(lib.uuid, row.id)
            return HTTPResponse.Status.ok
        }
        // G17 T6b: 特定ページの単頁/見開き override の書き戻し（Web リーダー/ネイティブ remote-client 共用）。
        // RW 専用（direction と異なりページ表示の恒久的な構造変更のため metadata 相当の権限を要求する）。
        // body: {page: Int, mode: Int?}（mode 省略 or null でクリア＝自動判定に戻す）。
        api.post("libraries/:lib/books/:id/page-layout") { [self] request, context in
            try context.requireEdit()
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: PageLayoutRequestBody.self, context: context)
            // ページ範囲は下限だけでなく上限も検証する。上限未チェックだと edit 権限で範囲外
            // index の book_page_layout 行を無制限に溜められ、manifest も肥大化する（G17 Codex Medium）。
            let content = try await self.contentCache.content(for: row, libraryUUID: lib.uuid)
            let pageCount = try await content.pageCount
            guard body.page >= 0, body.page < pageCount else { throw HTTPError(.badRequest) }
            if let mode = body.mode {
                guard mode == 0 || mode == 1 else { throw HTTPError(.badRequest) }
            }
            try lib.db.setPageOverride(bookID: row.id, page: body.page, mode: body.mode)
            self.notifyBookChanged(lib.uuid, row.id)
            return HTTPResponse.Status.ok
        }
        // 4.2c-9: レート更新（role 不問＝R でも可・共有評価）。0–5 検証。本を mutate するので onBookChanged。
        api.post("libraries/:lib/books/:id/rating") { [self] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: RatingRequestBody.self, context: context)
            guard (0...5).contains(body.rating) else { throw HTTPError(.badRequest) }
            try lib.db.setRating(bookID: row.id, rating: body.rating)
            self.notifyBookChanged(lib.uuid, row.id)
            return HTTPResponse.Status.ok
        }
        // 4.2c-9: 未読(unseen)更新（role 不問＝R でも可・共有閲覧状態）。
        api.post("libraries/:lib/books/:id/unseen") { [self] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: UnseenRequestBody.self, context: context)
            var patch = BookPatch()
            patch.unseen = body.unseen
            try lib.db.updateBook(id: row.id, patch: patch)
            self.notifyBookChanged(lib.uuid, row.id)
            return HTTPResponse.Status.ok
        }
        // 原本ファイルの一括ダウンロード（4.2 オフライン機能の土台・ストリーミングは YAGNI）。
        api.get("libraries/:lib/books/:id/file") { request, context in
            let (_, row) = try await resolver.resolveBook(request, context)
            guard let path = row.path, FileManager.default.fileExists(atPath: path) else {
                throw HTTPError(.notFound)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            var headers = HTTPFields()
            headers[.contentType] = "application/octet-stream"
            headers[.eTag] = bookETag(for: row)
            return Response(
                status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }
        // G8a: ライブ同期 SSE。接続トークンの scope で絞ったイベントをストリームする。
        // イベント本流とハートビートを 1 本の AsyncStream<ByteBuffer> に合流させ、
        // 切断（body 終了 = onTermination）で forward/heartbeat を cancel し EventHub から unsubscribe する。
        api.get("events") { [eventHub, grantsProvider = effectiveGrantsProvider] _, context in
            let (subID, events) = await eventHub.subscribe(scope: context.scope)
            let (frames, cont) = AsyncStream<ByteBuffer>.makeStream()
            // 接続時に認証された principal（grant id）と scope を保持し、ハートビート毎に再検証する
            // （C-③a・長寿命接続の即時失効反映）。
            //
            // G23 (#9/#10) Codex High #1: 以前はリクエストから**生のトークン文字列**を取り出して
            // 保持し、ハートビートで grant token と直接比較していた。クエリに載るのが短命
            // セッショントークンになった今、その比較は必ず失敗し、**約 5 秒ごとに切断→再接続**を
            // 繰り返していた。ミドルウェアが解決済みの `grantID` を使えば、トークンの種類に依存せず
            // 判定できる。秘密トークンを長寿命 Task に保持しなくて済む副次的な利点もある。
            //
            // あわせて `config.grantsProvider` ではなく `effectiveGrantsProvider` をキャプチャする。
            // 前者だと `grantRepository` 単独構成で grant 失効が既存 SSE に反映されない（同 High #1）。
            let subscribedGrantID = context.grantID
            let subscribedScope = context.scope
            // イベント → SSE フレーム
            let forward = Task {
                for await ev in events { cont.yield(ByteBuffer(string: ev.sseFrame())) }
                cont.finish()
            }
            // ~5s ハートビート（プロキシ/中間機器によるアイドル切断を防ぐ）。
            // G14 reconnect fix: 5s ハートビートでクライアントの有限アイドルタイムアウト(12s)未満に保ち、
            // 生存中の接続を維持しつつ、死んだ/到達不能サーバは早期にタイムアウト検知される。
            // グラントモードでは同時に grant の現存/scope を再検証し、失効・scope 変更を検知したら
            // ストリームを終了する（client は再接続時に BearerAuthMiddleware で 401 を受け取り停止する）。
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if let grantsProvider {
                        if !liveConnectionStillAuthorized(grantID: subscribedGrantID,
                                                          subscribedScope: subscribedScope,
                                                          grants: grantsProvider()) {
                            cont.finish()
                            break
                        }
                    }
                    cont.yield(ByteBuffer(string: ": ping\n\n"))
                }
            }
            cont.onTermination = { _ in
                forward.cancel()
                heartbeat.cancel()
                Task { await eventHub.unsubscribe(subID) }
            }
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-cache"
            headers[.connection] = "keep-alive"
            return Response(status: .ok, headers: headers, body: .init(asyncSequence: frames))
        }
        // G27b Task7: ローカル制御専用のライブラリ開閉（127.0.0.1 限定・共有サーバには絶対に出さない）。
        //
        // 任意パスを開ける API は実質的なファイルシステム探索になる。既存の `api`（/api/v1）group には
        // **絶対に**混ぜず、独立した `local` group として、config.enableLocalLibraryControl が true の
        // ときだけ登録する。ServerController（共有サーバ）はこのフラグを立てないため、buildApplication()
        // はこのブロック自体を実行せず、ルートが router に一切存在しない ―― 共有サーバ側では
        // BearerAuthMiddleware の 401/403 にすら到達せず 404 になる（ルート不在が唯一かつ最終的な
        // ゲート。tier チェックだけに頼らない ―― 将来 tier 昇格の穴が空いても共有サーバには出ない）。
        //
        // 認証自体は多層防御として api group と同じ BearerAuthMiddleware（adminTier）を適用する
        // （LocalControlController は adminTier: true で構成しているため、提示した RW トークンが
        // そのまま admin として扱われる・grants CRUD と同じ扱い）。
        if config.enableLocalLibraryControl {
            let local = router.group("local")
                .add(middleware: BearerAuthMiddleware(token: config.token, editToken: config.editToken, adminTier: config.adminTier, grantsProvider: effectiveGrantsProvider, sessionTokenStore: sessionTokenStore))
            local.post("libraries/open") { [openLibrary = config.openLibrary] request, context in
                try context.requireAdmin()
                guard let openLibrary else { throw HTTPError(.notImplemented) }
                let body = try await request.decode(as: OpenLibraryRequest.self, context: context)
                do {
                    let uuid = try await openLibrary(URL(fileURLWithPath: body.path))
                    return OpenLibraryReply(uuid: uuid)
                } catch let e as LocalLibraryControlError {
                    switch e {
                    case .invalidPath: throw HTTPError(.badRequest)
                    case .notFound: throw HTTPError(.notFound)
                    case .timeout, .bridgeUnavailable: throw HTTPError(.internalServerError)
                    }
                }
            }
            local.post("libraries/close") { [closeLibrary = config.closeLibrary] request, context in
                try context.requireAdmin()
                guard let closeLibrary else { throw HTTPError(.notImplemented) }
                let body = try await request.decode(as: CloseLibraryRequest.self, context: context)
                do {
                    try await closeLibrary(body.uuid)
                } catch let e as LocalLibraryControlError {
                    switch e {
                    case .notFound: throw HTTPError(.notFound)
                    case .invalidPath, .timeout, .bridgeUnavailable: throw HTTPError(.badRequest)
                    }
                }
                return HTTPResponse.Status.noContent
            }
        }
        // 静的 Web クライアント配信（認証不要 — ペアリング前にアプリ本体を読み込むため）。
        // FileMiddleware はルート未一致（.notFound）時のフォールバックとして働く: ルータ直登録
        // すると buildResponder() 時に NotFoundResponder をラップするため、/api/v1 配下の
        // 既存ルートは各自の stack（BearerAuthMiddleware 等）で処理され FileMiddleware に到達しない
        // （= API 認証はそのまま維持）。/ や /app.js のような未一致パスのみ静的ファイルを返す。
        // ★ルート登録規約: /api/v1 配下の新ルートは必ず `api` group（BearerAuthMiddleware 配下）に
        //   登録すること。router 直登録は無警告の認証バイパスになる（4.1a 最終レビュー指摘(3)）。
        // ★book を mutate する API は DB 書き込み成功後に config.onBookChanged?(lib.uuid, row.id) を
        //   呼ぶこと（リモート変更を Mac UI / 将来のクライアントへ即時反映するため・4.2a）。
        if !config.apiOnly, let webRoot = Bundle.module.url(forResource: "web", withExtension: nil)?.path {
            // Web シェル（html/js/css）は `Cache-Control: no-cache` で毎回再検証させる
            // （ETag で 304/200）。これが無いとブラウザのヒューリスティックキャッシュにより
            // アプリ更新後も古い JS が使われ続け、変更が反映されない（4.2c smoke で顕在化）。
            // 表紙/ページ画像は別ルートで immutable 長期キャッシュ（?v= 版管理）のため影響なし。
            router.add(middleware: FileMiddleware(
                webRoot,
                cacheControl: .init([(MediaType(type: .any), [.noCache])]),
                searchForIndexHtml: true))
        }
        // OpenAPI 仕様 + Redoc アセット配信（認証不要・ライブラリデータを含まない公開仕様）。
        // /openapi.yaml, /docs.html, /redoc.standalone.js を直接ルート登録し認証バイパスを明示。
        if let openapiDir = Bundle.module.url(forResource: "openapi", withExtension: nil) {
            @Sendable func serveFile(_ fileURL: URL, contentType: String) -> @Sendable (Request, LibraryRequestContext) async throws -> Response {
                { _, _ in
                    guard let data = try? Data(contentsOf: fileURL) else { throw HTTPError(.notFound) }
                    var headers = HTTPFields()
                    headers[.contentType] = contentType
                    headers[values: .cacheControl] = ["no-cache"]
                    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
                }
            }
            router.get("openapi.yaml", use: serveFile(openapiDir.appendingPathComponent("openapi.yaml"), contentType: "application/yaml"))
            router.get("docs", use: serveFile(openapiDir.appendingPathComponent("docs.html"), contentType: "text/html; charset=utf-8"))
            router.get("redoc.standalone.js", use: serveFile(openapiDir.appendingPathComponent("redoc.standalone.js"), contentType: "application/javascript"))
            if config.apiOnly {
                // API 専用エンドポイント: ルートで Redoc ドキュメントを返す（Web UI は載せない）。
                router.get("/", use: serveFile(openapiDir.appendingPathComponent("docs.html"), contentType: "text/html; charset=utf-8"))
            }
        }
        return Application(
            router: router,
            configuration: .init(address: .hostname(config.host, port: config.port))
        )
    }

    /// 4.2c-6b: 選択ページから Thumbnails/<id>/thumbnail.jpg を再生成する（App の CoverRefresher 相当）。
    /// preferredName=nil は自動先頭ページ。
    ///
    /// G21 followup review（Important #1, #2）:
    /// - フォーマット判定は `CoverRefresher.extractCoverData`（AppCore）に委譲する。フォルダ/zip 系に
    ///   加え単独 PDF・単独画像も対応し、真に表紙を作れない形式（動画・epub・txt 等）だけ
    ///   `HTTPError(.badRequest, message:)` を投げる（クライアントが説明できる 4xx。旧実装は
    ///   PDF/単独画像を含め非対応形式をすべて 500 にしていた）。抽出・resize は
    ///   `CoverRefresher` 側で `Task.detached` に包まれており、呼び出し元の actor（App 側の
    ///   MainActor 含む）をブロックしない（re-review Important 指摘）。
    /// - `extractCoverData` の `await`（アーカイブ展開・大きいファイルだと数秒かかりうる）の**後**、
    ///   ファイル書き込みの**直前**に `db.fetchBook` で行を再取得し `CoverSource.isExternal` を
    ///   再確認する。呼び出し側（PUT cover / POST cover/regenerate / relink）はどれも「この行が
    ///   呼び出し開始時点で external でない」ことしか保証しないため、この await の間に
    ///   別クライアントが外部表紙をアップロードすると、初期スナップショットの判定だけでは
    ///   それを上書きしてしまう（Sources/AppCore/CoverCompression.swift:40-44 で一度直した
    ///   whole-library ジョブと同じクラスの不具合）。再確認と書き込みの間に await は無い
    ///   （`simulateRaceBeforeWrite` はテスト専用フックで、既定は no-op）。
    ///
    ///   re-review Critical fix: 「external かつファイルが既に存在する」ときだけ no-op にする
    ///   （ファイル存在チェックを追加）。DELETE は `Thumbnails/<id>` を丸ごと消し、restore は
    ///   行を `@external` のまま再挿入して本関数を呼ぶ（BookRestoreEndpointTests になかった
    ///   経路）。ここでファイル不在なのに external だからと no-op すると、そのブランチが
    ///   意図していた「外部サムネ不在→自動へフォールバックして恒久欠番を防ぐ」動作が死ぬ。
    ///   `PUT /cover-image` は thumbnail を atomic 書き込みした**後**に DB を `@external` にする
    ///   （直下の実装参照）ため、「行が external」は「ファイルが既に存在する」を含意する —
    ///   つまりファイル存在チェックを足しても Important #1 のレースは閉じたままである
    ///   （別クライアントが外部表紙をアップロードした場合、その時点で書き込みも完了済み）。
    /// `regenerateThumbnail` の結果。G21 followup Codex review #4 の crop クリア判定に使う。
    /// crop（消えた外部画像用に authored された矩形）は「フォールバックで自動表紙を**実際に
    /// 書いた**」ときだけクリアしてよい。抽出失敗や external 保護 no-op では自動表紙が
    /// 書かれていないため、crop を消すと復元した矩形を根拠なく失うことになる（成功を確認して
    /// から消す＝`.wroteAuto` のときだけ）。
    enum CoverRegenOutcome: Sendable {
        case wroteAuto        // 自動（先頭ページ等）表紙を書いた
        case skippedExternal  // 外部表紙へ切り替わり済み＋ファイル現存で no-op（Important #1 レース保護）
    }

    @discardableResult
    static func regenerateThumbnail(
        bookID: Int, sourceURLPath: String?, preferredName: String?, bundleURL: URL, db: Database,
        simulateRaceBeforeWrite: (@Sendable () async -> Void)? = nil
    ) async throws -> CoverRegenOutcome {
        guard let path = sourceURLPath else {
            throw HTTPError(.badRequest, message: "本の実ファイルが見つかりません")
        }
        let sourceURL = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try await CoverRefresher.extractCoverData(sourceURL: sourceURL, preferredName: preferredName)
        } catch CoverRefreshError.unsupportedFormat {
            let ext = sourceURL.pathExtension
            throw HTTPError(.badRequest, message: "この形式（.\(ext.isEmpty ? "?" : ext)）は表紙を自動生成できません")
        }
        let resized = await CoverRefresher.resizeCoverDataOffMain(data, maxPixelSize: 1200)
        let url = coverURL(bundleURL: bundleURL, bookID: bookID)
        await simulateRaceBeforeWrite?()   // テスト専用: 再確認直前に割り込ませるためのフック（本番は常に nil）
        // Important #1 の再確認（この行の直後に await は無い＝書き込みまでアトミック）。
        if let fresh = try? db.fetchBook(id: bookID), CoverSource.isExternal(fresh.coverImageName),
           FileManager.default.fileExists(atPath: url.path) {
            return .skippedExternal   // 外部表紙へ切り替わっていて、かつその表紙ファイルが現存する: no-op（既存 200/204 を維持）
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try resized.write(to: url)
        return .wroteAuto
    }

    /// G12b-2c: GET/PUT 応答用に現在の監視設定を DTO 化する（folders に subfolderMode 反映＋presets 同梱）。
    static func buildWatchConfigDTO(lib: ServedLibrary) throws -> WatchConfigDTO {
        let enabled = ((try? lib.db.getLibrarySetting(key: "folder_watch_enabled")) ?? nil)
            .map { $0 == "1" || $0 == "true" } ?? false
        let foldersJSON = (try? lib.db.getLibrarySetting(key: "watched_folders")) ?? nil
        let folders: [WatchedFolder] = foldersJSON.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([WatchedFolder].self, from: $0) } ?? []
        let presetsJSON = (try? lib.db.getLibrarySetting(key: "filename_format_presets")) ?? nil
        let presets: [FilenameFormatPreset] = presetsJSON.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([FilenameFormatPreset].self, from: $0) } ?? []
        let folderDTOs = folders.map { f in
            WatchedFolderDTO(id: f.id, path: f.path, enabled: f.enabled, presetID: f.presetID,
                             baseline: f.baseline,
                             subfolderMode: WatchedFolderDTO.SubfolderMode(rawValue: f.subfolderMode.rawValue) ?? .topLevelOnly)
        }
        let presetDTOs = presets.map { FilenameFormatPresetDTO(id: $0.id, name: $0.displayName) }
        return WatchConfigDTO(enabled: enabled, folders: folderDTOs, presets: presetDTOs)
    }
}

/// unlock リクエストボディ。
struct UnlockRequestBody: Decodable {
    let password: String
}

/// progress 書き込みリクエストボディ（ファイルスコープ — swiftc ASTMangler 対策）。
struct ProgressRequestBody: Decodable {
    let page: Int
    /// G26 Codex Important #1: ユーザーが明示的に「最初から」を選んだことを表す任意フィールド。
    /// 省略（旧クライアント）＝ nil ＝ false。true のとき打ち切り読みの保護下限を 0 に落とす。
    let restart: Bool?
}

/// 方向書き込みボディ（swiftc ASTMangler 対策でファイルスコープ）。
struct DirectionRequestBody: Decodable {
    let direction: String?
}

/// G17 T6b: ページ単位レイアウト override 書き込みボディ（swiftc ASTMangler 対策でファイルスコープ）。
/// mode: 0=forcePair / 1=forceSolo / nil(省略含む)=クリア（自動判定に戻す）。
struct PageLayoutRequestBody: Decodable {
    let page: Int
    let mode: Int?
}

/// 4.2c-9: レート更新リクエストボディ（ファイルスコープ）。role 不問（R でも可・共有評価）。
struct RatingRequestBody: Decodable {
    let rating: Int
}

/// 4.2c-9: 未読(unseen)更新リクエストボディ（ファイルスコープ）。role 不問（R でも可・共有閲覧状態）。
struct UnseenRequestBody: Decodable {
    let unseen: Bool
}

/// ?filter=<URL-encoded JSON FilterState> をデコードする。
/// - パラメータ無し / 空文字列 → 空 `FilterState`（フィルタ指定なし）
/// - JSON として壊れている → **`HTTPError(.badRequest)`**
///
/// G26 以前は両者を空 `FilterState` に潰していたため、**壊れた（あるいは部分的な）JSON を
/// 送ると絞り込みが黙って無視され、絞られていない一覧が返っていた**。部分 JSON は
/// `FilterState.init(from:)` が既定値で受けるようになったので、ここに来る失敗は
/// 「JSON として妥当でない」場合だけになる。
private func decodeFilterState(from jsonString: String?) throws -> FilterState {
    guard let s = jsonString, !s.isEmpty else { return FilterState() }
    guard let data = s.data(using: .utf8),
          let fs = try? JSONDecoder().decode(FilterState.self, from: data)
    else { throw HTTPError(.badRequest) }
    return fs
}

/// ?browse=<URL-decoded JSON [{"column":…,"value":…}]> から [(String,String)] をデコードする。
/// クライアントは [BrowseConstraint] (オブジェクト配列) として送信する。
/// - 入力が nil / 空文字列 / JSON として不正（デコード失敗）の場合: 空配列にフォールバックする
///   （呼び出し側で 400 にしない）。
/// - 入力が JSON として妥当だが、含まれる列名が許可リスト外の場合: `HTTPError(.badRequest)` を
///   投げる（SQL injection 防御・4.2b-1b-2b）。この 2 条件は排他的な入力ケースであり、
///   同じ入力に対して両方が同時に成り立つことはない。
private func decodeBrowseConstraintsValidated(from jsonString: String?) throws -> [(String, String)] {
    guard let s = jsonString, !s.isEmpty,
          let data = s.data(using: .utf8),
          let arr = try? JSONDecoder().decode([BrowseConstraint].self, from: data)
    else { return [] }
    let pairs = arr.map { ($0.column, $0.value) }
    for (column, _) in pairs {
        guard allowedFacetColumns.contains(column) else { throw HTTPError(.badRequest) }
    }
    return pairs
}

/// ?scope=<scope>&scopeId=<Int64>&recentDays=<Int> から SidebarScope をデコードする。
/// 不正値・未知の scope は .library にフォールバックする（呼び出し側で 400 にしない）。
private func decodeSidebarScope(scope: String?, scopeId: Int64?, recentDays: Int?) -> SidebarScope {
    switch scope {
    case "favorites":
        return scopeId.map { SidebarScope.favorites(playlistID: $0) } ?? .library
    case "recent":
        return .recent(days: recentDays ?? 7)
    case "shelf":
        return scopeId.map { SidebarScope.shelf(playlistID: $0) } ?? .library
    case "smartShelf":
        return scopeId.map { SidebarScope.smartShelf(playlistID: $0) } ?? .library
    default:
        return .library
    }
}

