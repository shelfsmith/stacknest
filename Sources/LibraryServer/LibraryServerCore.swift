// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore
import Hummingbird

/// LibraryServer の設定（4.1b でアプリ設定 UI から渡される）。
public struct LibraryServerConfig: Sendable {
    public var host: String
    public var port: Int
    /// デバイス認証用の共有トークン（QR でクライアントに渡す）。
    public var token: String
    /// 画像縮小器（既定は縮小しない Passthrough）。App は ImageIOTranscoder を注入する。
    public var transcoder: any ImageTranscoding
    /// 本ごと pageDirection が未設定のときの既定方向（アプリ起動時にスナップショット）。
    /// manifest エンドポイントが null を返さずに実効方向を返すために使う（4.1c）。
    public var defaultPageDirection: PageDirection
    // dual-stack 化は呼び出し側が host: "::" を明示注入する
    // （Linux は v6only sysctl 依存のため既定は互換性優先の 0.0.0.0）。
    public init(host: String = "0.0.0.0", port: Int, token: String,
                transcoder: any ImageTranscoding = PassthroughTranscoder(),
                defaultPageDirection: PageDirection = .rightToLeft) {
        self.host = host
        self.port = port
        self.token = token
        self.transcoder = transcoder
        self.defaultPageDirection = defaultPageDirection
    }
}

/// サーバの capability（spec §3.3 /server/info）。Docker 版は fileOps=false 等で差別化。
public struct ServerCapabilities: Codable, Sendable {
    public var version: String
    public var fileOps: Bool
    public var transcode: Bool
    public var formats: [String]
    public static let inApp = ServerCapabilities(
        version: "1", fileOps: true, transcode: false, formats: ["zip", "rar", "7z", "folder", "image", "pdf"]
    )
}

/// LibraryServer 共通の RequestContext。JSON の Date を ISO8601 に固定する
/// （Hummingbird 2.25 の既定も ISO8601 だが、upstream の既定変更に依存しないよう明示。
/// テスト側デコーダも .iso8601 で一致させること — plan 設計ノート）。
public struct LibraryRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage

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

/// HTTP サーバ本体。Router 構築と Application 生成を担う。
/// AppKit / ImageIO / PDFKit を import しないこと（Linux 移植規律・spec §3.2）。
public struct LibraryServerCore: Sendable {
    public let config: LibraryServerConfig
    let dataSource: any LibraryServerDataSource
    /// ロック庫の短命トークン（メモリのみ・再起動で失効）。
    let tokenStore = LibraryTokenStore()
    /// 本ごとの BookContent ハンドルキャッシュ（アーカイブ再オープン排除・spec §3.3）。
    let contentCache = BookContentCache(ttlSeconds: 300)

    public init(config: LibraryServerConfig, dataSource: any LibraryServerDataSource) {
        self.config = config
        self.dataSource = dataSource
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
            .add(middleware: BearerAuthMiddleware(token: config.token))
        let dataSource = self.dataSource
        let tokenStore = self.tokenStore
        let resolver = LibraryResolver(dataSource: dataSource, tokenStore: tokenStore)
        api.get("libraries") { _, _ in
            let libs = await dataSource.servedLibraries()
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
        // books 一覧（ページング・検索・ソート・進行状況）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/books") { request, context in
            let uuid = try context.parameters.require("lib")
            guard let lib = try await resolver.resolve(
                uuid: uuid, libraryToken: libraryToken(from: request)
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
            let query = BooksQuery(
                q: qp.get("q"),
                sort: sort,
                order: order,
                page: max(1, qp.get("page", as: Int.self) ?? 1),
                per: min(200, max(1, qp.get("per", as: Int.self) ?? 100))
            )
            return try query.run(on: lib)
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
        // 閲覧進行状況の書き込み（last_page のみ更新・viewer フラグ保持）。
        api.post("libraries/:lib/books/:id/progress") { request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let body = try await request.decode(as: ProgressRequestBody.self, context: context)
            guard body.page >= 0 else { throw HTTPError(.badRequest) }
            try lib.db.updateLastPage(bookID: row.id, lastPage: body.page)
            return HTTPResponse.Status.ok
        }
        // ページ方向の書き戻し（Web リーダーでの変更を本ごと DB に反映・4.1c F2b）。
        api.post("libraries/:lib/books/:id/direction") { request, context in
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
        // 静的 Web クライアント配信（認証不要 — ペアリング前にアプリ本体を読み込むため）。
        // FileMiddleware はルート未一致（.notFound）時のフォールバックとして働く: ルータ直登録
        // すると buildResponder() 時に NotFoundResponder をラップするため、/api/v1 配下の
        // 既存ルートは各自の stack（BearerAuthMiddleware 等）で処理され FileMiddleware に到達しない
        // （= API 認証はそのまま維持）。/ や /app.js のような未一致パスのみ静的ファイルを返す。
        // ★ルート登録規約: /api/v1 配下の新ルートは必ず `api` group（BearerAuthMiddleware 配下）に
        //   登録すること。router 直登録は無警告の認証バイパスになる（4.1a 最終レビュー指摘(3)）。
        if let webRoot = Bundle.module.url(forResource: "web", withExtension: nil)?.path {
            router.add(middleware: FileMiddleware(webRoot, searchForIndexHtml: true))
        }
        return Application(
            router: router,
            configuration: .init(address: .hostname(config.host, port: config.port))
        )
    }
}

/// /libraries の一覧 1 件分（spec §3.3）。
public struct LibraryDTO: Codable, Sendable {
    public let id: String
    public let name: String
    public let locked: Bool
    public let bookCount: Int
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

/// unlock 成功レスポンス（短命ライブラリトークン）。
struct UnlockReply: ResponseEncodable {
    let libraryToken: String
}

extension ServerCapabilities: ResponseEncodable {}
extension LibraryDTO: ResponseEncodable {}
extension BookPageDTO: ResponseEncodable {}
