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
    /// G12b-3a: 監視フォルダの「今すぐスキャン」がリクエストされたとき App に通知する（libraryUUID）。
    /// App は該当ライブラリの FolderWatcher の scanNow() を発火する。
    public var onScanNowRequested: (@Sendable (String) -> Void)?
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
                onScanNowRequested: (@Sendable (String) -> Void)? = nil) {
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
        self.onScanNowRequested = onScanNowRequested
    }
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

/// HTTP サーバ本体。Router 構築と Application 生成を担う。
/// AppKit / ImageIO / PDFKit を import しないこと（Linux 移植規律・spec §3.2）。
public struct LibraryServerCore: Sendable {
    private static let backupLogger = Logger(subsystem: "app.shelfsmith.stacknest", category: "Backup")
    public let config: LibraryServerConfig
    let dataSource: any LibraryServerDataSource
    /// ロック庫の短命トークン（メモリのみ・再起動で失効）。
    let tokenStore = LibraryTokenStore()
    /// 本ごとの BookContent ハンドルキャッシュ（アーカイブ再オープン排除・spec §3.3）。
    let contentCache = BookContentCache(ttlSeconds: 300)
    /// G8a: ライブ同期の配信ハブ。/events が subscribe し、mutation が publish する。
    public let eventHub = EventHub()
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

    public init(config: LibraryServerConfig, dataSource: any LibraryServerDataSource) {
        self.config = config
        self.dataSource = dataSource
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
        let router = Router(context: LibraryRequestContext.self)
        // /server/info は認証不要（ペアリング前の到達性確認用）。
        let transcodes = config.transcoder.supportsScaling
        router.get("/api/v1/server/info") { _, _ in
            var caps = ServerCapabilities.inApp
            caps.transcode = transcodes
            return caps
        }
        // それ以外の API は Bearer トークン認証配下。
        let api = router.group("api/v1")
            .add(middleware: BearerAuthMiddleware(token: config.token, editToken: config.editToken, adminTier: config.adminTier, grantsProvider: config.grantsProvider))
        let dataSource = self.dataSource
        let tokenStore = self.tokenStore
        let resolver = LibraryResolver(dataSource: dataSource, tokenStore: tokenStore)
        // 提示トークンの tier（read/edit/admin）と role（互換）、スコープを返す（4.2b-3・B1・B2b）。
        api.get("me") { _, context in
            MeReply(tier: context.tier, scope: context.scope)
        }
        // グラント CRUD（admin 専用）。CRUD は GrantStore(UserDefaults.standard) を更新し、
        // 認証は grantsProvider が毎リクエスト GrantStore を参照するため即時反映される（C-③a）。
        api.get("grants") { _, context in
            try context.requireAdmin()
            return GrantStore.list().map {
                GrantDTO(id: $0.id, label: $0.label, token: $0.token, tier: $0.tier, scope: $0.scope)
            }
        }
        api.post("grants") { request, context in
            try context.requireAdmin()
            let req = try await request.decode(as: GrantCreateRequest.self, context: context)
            let g = Grant(id: UUID().uuidString, label: req.label,
                          token: ServerPreferences.generateToken(),
                          tier: req.tier, scope: req.scope, createdAt: Date())
            GrantStore.add(g)
            return GrantDTO(id: g.id, label: g.label, token: g.token, tier: g.tier, scope: g.scope)
        }
        api.patch("grants/:id") { request, context in
            try context.requireAdmin()
            let id = try context.parameters.require("id")
            guard var g = GrantStore.list().first(where: { $0.id == id }) else {
                throw HTTPError(.notFound)
            }
            let req = try await request.decode(as: GrantUpdateRequest.self, context: context)
            if let l = req.label { g.label = l }
            if let t = req.tier  { g.tier  = t }
            if let s = req.scope { g.scope = s }
            GrantStore.update(g)
            return GrantDTO(id: g.id, label: g.label, token: g.token, tier: g.tier, scope: g.scope)
        }
        api.delete("grants/:id") { _, context in
            try context.requireAdmin()
            let id = try context.parameters.require("id")
            GrantStore.delete(id: id)
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
            guard let lib = await dataSource.servedLibraries().first(where: { $0.uuid == uuid }) else {
                throw HTTPError(.notFound)
            }
            let body = try await request.decode(as: UnlockRequestBody.self, context: context)
            guard lib.verifyPassword(body.password) else { throw HTTPError(.forbidden) }
            return UnlockReply(libraryToken: await tokenStore.issueToken(for: uuid))
        }
        // books 一覧（ページング・検索・ソート・進行状況・scope/filter/browse）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/books") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(
                uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope
            ) else {
                throw HTTPError(.notFound)
            }
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
            let filter = decodeFilterState(from: qp.get("filter"))
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
                page: max(1, qp.get("page", as: Int.self) ?? 1),
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(
                uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope
            ) else {
                throw HTTPError(.notFound)
            }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            let shelfID = try context.parameters.require("id", as: Int64.self)
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            let shelfID = try context.parameters.require("id", as: Int64.self)
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
            guard let row = try lib.db.fetchAllShelves().first(where: { $0.id == shelfID }) else { throw HTTPError(.notFound) }
            if row.kind == "favorites" { throw HTTPError(.conflict) }
            try lib.db.deleteShelf(id: shelfID)
            self.notifySettingsChanged(lib.uuid)
            return Response(status: .noContent)
        }
        // A1: スマート棚の条件取得（read）。
        api.get("libraries/:lib/shelves/:id/conditions") { request, context in
            let uuid = try context.parameters.require("lib")
            let shelfID = try context.parameters.require("id", as: Int64.self)
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
            guard let row = try lib.db.fetchAllShelves().first(where: { $0.id == shelfID }) else { throw HTTPError(.notFound) }
            guard row.isSmart else { throw HTTPError(.conflict) }
            guard let conditions = try lib.db.fetchSmartShelfConditions(id: shelfID) else { throw HTTPError(.notFound) }
            return conditions
        }
        // A1: スマート棚の条件更新（RW）。
        api.put("libraries/:lib/shelves/:id/conditions") { [self] request, context in
            try context.requireEdit()
            let uuid = try context.parameters.require("lib")
            let shelfID = try context.parameters.require("id", as: Int64.self)
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            let shelfID = try context.parameters.require("id", as: Int64.self)
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            let shelfID = try context.parameters.require("id", as: Int64.self)
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
            guard let row = try lib.db.fetchAllShelves().first(where: { $0.id == shelfID }) else { throw HTTPError(.notFound) }
            guard !row.isSmart else { throw HTTPError(.conflict) }
            let body = try await request.decode(as: ShelfBooksRequest.self, context: context)
            try lib.db.removeBooksFromShelf(playlistID: shelfID, bookIDs: body.bookIDs)
            self.notifyStructureChanged(lib.uuid)
            return Response(status: .noContent)
        }
        // ファセット（列の distinct 値リスト）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/facets/:field") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(
                uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope
            ) else {
                throw HTTPError(.notFound)
            }
            let field = try context.parameters.require("field")
            guard allowedFacetColumns.contains(field) else { throw HTTPError(.badRequest) }
            let qp = request.uri.queryParameters
            let filter = decodeFilterState(from: qp.get("filter"))
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
            let comps = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            for root in roots {
                let rootComps = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else {
                throw HTTPError(.notFound)
            }
            let json = (try? lib.db.getLibrarySetting(key: "stamp_definitions")) ?? nil
            let map: [String: [String]] = json
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
            return StampDefinitionsDTO(definitions: map)
        }
        // 4.2c-6a: スタンプ定義の置換（RW）。許可カラムのみ採用しマップ全体を保存。
        api.put("libraries/:lib/stamp-definitions") { [self] request, context in
            try context.requireEdit()
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else {
                throw HTTPError(.notFound)
            }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else {
                throw HTTPError(.notFound)
            }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else {
                throw HTTPError(.notFound)
            }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else {
                throw HTTPError(.notFound)
            }
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
                if let trackedPath = await self.deletedPathTracker.take(uuid: lib.uuid, bookID: dto.id) {
                    effectiveDTO.path = trackedPath
                } else if let p = dto.path {
                    pathIsSafe = isPathWithinAllowedRoots(p, roots: roots)
                    if !pathIsSafe { effectiveDTO.path = nil }
                }
                do {
                    try lib.db.restoreBook(bookRow(from: effectiveDTO))
                    restoredCount += 1
                    restoredIDs.append(dto.id)
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
                        try? await Self.regenerateThumbnail(
                            bookID: dto.id, sourceURLPath: effectiveDTO.path,
                            preferredName: dto.coverImageName, bundleURL: lib.bundleURL)
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
                entries = (try? await ex.listImageEntries(in: URL(fileURLWithPath: path))) ?? []
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
            let etag = bookETag(for: row) + "-entry-" + String(name.hashValue)
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
                    bundleURL: lib.bundleURL)
            }
            if body.setCoverCropRect {
                try lib.db.updateBookCoverCropRect(id: row.id, json: body.coverCropRect)
            }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(
                uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope
            ) else {
                throw HTTPError(.notFound)
            }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(
                uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope
            ) else {
                throw HTTPError(.notFound)
            }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
            return try Self.buildWatchConfigDTO(lib: lib)
        }
        // A2: 監視フォルダ設定の更新（RW）。blind-replace ではなく id マージ:
        // 既存 id は baseline をサーバ保持・編集反映／新規 id はパス検証＋baseline スキャン／消えた id は削除。
        api.put("libraries/:lib/watch-config") { [self] request, context in
            try context.requireAdmin()
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
                        folder: URL(fileURLWithPath: f.path), recurse: mode == .recurse).map { $0.path }
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
            let uuid = try context.parameters.require("lib")
            guard (try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope)) != nil else { throw HTTPError(.notFound) }
            config.onScanNowRequested?(uuid)
            return HTTPResponse.Status.noContent
        }
        // G12b-3c: 既存フォルダ一括再取込（admin）= 該当 folder の baseline をクリアして scan。
        // dedup が既取込済みファイルの再取込を防ぐため、baseline を空にしても実害はない。
        api.post("libraries/:lib/watch/import-existing") { [self] request, context in
            try context.requireAdmin()
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
        api.post("libraries/:lib/lock") { [self] request, context in
            try context.requireAdmin()
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
            let body = try await request.decode(as: LockRequest.self, context: context)
            guard !body.password.isEmpty else { throw HTTPError(.badRequest) }
            let salt = LibraryLock.generateSalt()
            let hash = LibraryLock.computeHash(password: body.password, saltHex: salt)
            try lib.db.setLibrarySetting(key: "lock_password_salt", value: salt)
            try lib.db.setLibrarySetting(key: "lock_password_hash", value: hash)
            self.notifySettingsChanged(lib.uuid)
            return HTTPResponse.Status.noContent
        }
        // A2: ライブラリロック解除（admin）。hash と salt を削除。
        api.delete("libraries/:lib/lock") { [self] request, context in
            try context.requireAdmin()
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
            try lib.db.deleteLibrarySetting(key: "lock_password_hash")
            try lib.db.deleteLibrarySetting(key: "lock_password_salt")
            self.notifySettingsChanged(lib.uuid)
            return HTTPResponse.Status.noContent
        }
        // A2: per-library 取り込み設定の取得（R 可）。未設定キーは nil（= グローバル既定に委譲）。
        api.get("libraries/:lib/import-config") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
            let ac = ((try? lib.db.getLibrarySetting(key: ImportDefaults.libAutoClassifyKey)) ?? nil).map { $0 == "1" || $0 == "true" }
            let th = ((try? lib.db.getLibrarySetting(key: ImportDefaults.libThickThresholdKey)) ?? nil).flatMap { Int($0) }
            return ImportConfigDTO(autoClassifyEnabled: ac, thickBookThreshold: th)
        }
        // A2: per-library 取り込み設定の更新（RW）。nil 指定は override 削除（= グローバル既定へ戻す）。
        api.put("libraries/:lib/import-config") { [self] request, context in
            try context.requireAdmin()
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
            let dto = try await request.decode(as: ImportConfigDTO.self, context: context)
            if let ac = dto.autoClassifyEnabled { try lib.db.setLibrarySetting(key: ImportDefaults.libAutoClassifyKey, value: ac ? "true" : "false") } else { try lib.db.deleteLibrarySetting(key: ImportDefaults.libAutoClassifyKey) }
            if let th = dto.thickBookThreshold { try lib.db.setLibrarySetting(key: ImportDefaults.libThickThresholdKey, value: String(max(5, min(100, th)))) } else { try lib.db.deleteLibrarySetting(key: ImportDefaults.libThickThresholdKey) }
            self.notifySettingsChanged(lib.uuid)
            return dto
        }
        // G12b-3a: 一般設定の取得（R 可）。
        api.get("libraries/:lib/general-settings") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
            let rows = (try? lib.db.integrityCheck()) ?? ["(エラー)"]
            return IntegrityCheckDTO(healthy: rows == ["ok"], rows: rows)
        }
        // G12b-3a: 今すぐバックアップ（admin）。同一 lib.db から作成し世代 prune。
        api.post("libraries/:lib/backup-now") { request, context in
            try context.requireAdmin()
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
            await self.maintenanceRegistry.cancel(library: lib.uuid)
            return HTTPResponse.Status.noContent
        }
        // G14: リモートサイドバーの安定件数（ライブラリ総数・最近件数）。scope 非依存。read で可。
        api.get("libraries/:lib/counts") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            let uuid = try context.parameters.require("lib")
            let bookID = try context.parameters.require("id", as: Int.self)
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
            guard ((try? lib.db.fetchBook(id: bookID)) ?? nil) != nil else { throw HTTPError(.notFound) }
            let body = try await request.decode(as: RelinkRequest.self, context: context)
            guard !body.newPath.isEmpty else { throw HTTPError(.badRequest) }
            try lib.db.relinkBook(id: bookID, newPath: body.newPath)
            self.notifyStructureChanged(lib.uuid)
            return HTTPResponse.Status.noContent
        }
        // A2: 重複スキャン（RW・content_hash を計算/キャッシュしグループ返却）。
        api.post("libraries/:lib/duplicates/scan") { request, context in
            try context.requireEdit()
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken(from: request), scope: context.scope) else { throw HTTPError(.notFound) }
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
            return cacheableImageResponse(data: data, etag: etag, request: request)
        }
        // 本のマニフェスト（ページ数・方向・形式・ETag）。
        // direction は実効方向（本ごと override があればその値、なければ config.defaultPageDirection）を
        // 常に返す。null を返さないことで Web リーダーがアプリ設定と同じ既定方向で開く（4.1c）。
        api.get("libraries/:lib/books/:id/manifest") { [config] request, context in
            let (_, row) = try await resolver.resolveBook(request, context)
            let content = try BookContentFactory.make(for: row)
            let pageCount = try await content.pageCount
            return ManifestDTO(
                pageCount: pageCount,
                direction: directionString(row.pageDirection ?? config.defaultPageDirection),
                format: formatString(BookCategory.classify(path: row.path ?? "")),
                etag: bookETag(for: row)
            )
        }
        // ページ画像（ハンドルキャッシュ経由・ETag + immutable）。
        // 範囲外 → 404 / 範囲内の描画失敗 → 500（BookContentError.renderFailed 分離・4.1a）。
        // ?maxw= が指定された場合は ETag に幅を織り込み、縮小バイトを返す（4.1c）。
        let contentCache = self.contentCache
        api.get("libraries/:lib/books/:id/pages/:n") { [config] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let n = try context.parameters.require("n", as: Int.self)
            let content = try await contentCache.content(for: row, libraryUUID: lib.uuid)
            let maxw = request.uri.queryParameters.get("maxw", as: Int.self)
            let etag = maxwETag(bookETag(for: row) + "-p\(n)", maxw: maxw)
            if request.headers[.ifNoneMatch] == etag { return Response(status: .notModified) }
            do {
                var data = try await content.imageData(at: n)
                if let maxw, maxw > 0 { data = config.transcoder.scaled(data, maxWidth: maxw) }
                return cacheableImageResponse(data: data, etag: etag, request: request)
            } catch let e as BookContentError {
                switch e {
                case .pageOutOfRange: throw HTTPError(.notFound)
                case .renderFailed: throw HTTPError(.internalServerError)
                default: throw HTTPError(.notFound)
                }
            }
        }
        // 閲覧進行状況の書き込み（last_page）＋ mark-as-read（Mac ビューワとパリティ: unseen=false /
        // play_date=now）。本を mutate するので最後に onBookChanged を発火し Mac UI / 将来のクライアントへ
        // 即時反映させる（4.2a）。viewer フラグ（spread/coverOffset）は触らない。
        api.post("libraries/:lib/books/:id/progress") { [config] request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: ProgressRequestBody.self, context: context)
            guard body.page >= 0 else { throw HTTPError(.badRequest) }
            try lib.db.updateLastPage(bookID: row.id, lastPage: body.page)
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
        api.get("events") { [eventHub, grantsProvider = config.grantsProvider] request, context in
            let (subID, events) = await eventHub.subscribe(scope: context.scope)
            let (frames, cont) = AsyncStream<ByteBuffer>.makeStream()
            // 接続時に提示されたトークンと scope を保持し、ハートビート毎に再検証する（C-③a・長寿命接続の即時失効反映）。
            let presentedToken: String? = {
                if let header = request.headers[.authorization], header.hasPrefix("Bearer ") {
                    return String(header.dropFirst("Bearer ".count))
                }
                return request.uri.queryParameters.get("token")
            }()
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
                    if let grantsProvider, let presentedToken {
                        if !liveConnectionStillAuthorized(presentedToken: presentedToken,
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
    /// preferredName=nil は自動先頭ページ。非対応/失敗は throws（呼び出し側で 500）。
    static func regenerateThumbnail(bookID: Int, sourceURLPath: String?, preferredName: String?, bundleURL: URL) async throws {
        guard let path = sourceURLPath, let ex = ArchiveAdapter.coverExtractor(for: URL(fileURLWithPath: path)) else {
            throw HTTPError(.internalServerError)
        }
        let data = try await ex.extractCoverImage(from: URL(fileURLWithPath: path), preferredName: preferredName)
        let resized = CoverImageResizer.resizeJPEG(data, maxPixelSize: 1200)
        let url = coverURL(bundleURL: bundleURL, bookID: bookID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try resized.write(to: url)
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
}

/// 方向書き込みボディ（swiftc ASTMangler 対策でファイルスコープ）。
struct DirectionRequestBody: Decodable {
    let direction: String?
}

/// 4.2c-9: レート更新リクエストボディ（ファイルスコープ）。role 不問（R でも可・共有評価）。
struct RatingRequestBody: Decodable {
    let rating: Int
}

/// 4.2c-9: 未読(unseen)更新リクエストボディ（ファイルスコープ）。role 不問（R でも可・共有閲覧状態）。
struct UnseenRequestBody: Decodable {
    let unseen: Bool
}

/// ?filter=<URL-decoded JSON> から FilterState をデコードする。
/// 不正 JSON / nil は空の FilterState にフォールバックする（呼び出し側で 400 にしない）。
private func decodeFilterState(from jsonString: String?) -> FilterState {
    guard let s = jsonString, !s.isEmpty,
          let data = s.data(using: .utf8),
          let fs = try? JSONDecoder().decode(FilterState.self, from: data)
    else { return FilterState() }
    return fs
}

/// ?browse=<URL-decoded JSON [{"column":…,"value":…}]> から [(String,String)] をデコードする。
/// クライアントは [BrowseConstraint] (オブジェクト配列) として送信する。
/// 不正 JSON / nil は空配列にフォールバックする（バリデーションなし版・内部利用）。
private func decodeBrowseConstraints(from jsonString: String?) -> [(String, String)] {
    guard let s = jsonString, !s.isEmpty,
          let data = s.data(using: .utf8),
          let arr = try? JSONDecoder().decode([BrowseConstraint].self, from: data)
    else { return [] }
    return arr.map { ($0.column, $0.value) }
}

/// ?browse=<URL-decoded JSON [{"column":…,"value":…}]> から [(String,String)] をデコードし、
/// 列名が許可リスト外なら HTTPError(.badRequest) を投げる（SQL injection 防御・4.2b-1b-2b）。
private func decodeBrowseConstraintsValidated(from jsonString: String?) throws -> [(String, String)] {
    let pairs = decodeBrowseConstraints(from: jsonString)
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

