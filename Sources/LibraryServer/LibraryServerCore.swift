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
    public init(host: String = "0.0.0.0", port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
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
        router.get("/api/v1/server/info") { _, _ in
            ServerCapabilities.inApp
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
            let libraryToken = request.headers[.init("X-Library-Token")!]
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken) else {
                throw HTTPError(.notFound)
            }
            let qp = request.uri.queryParameters
            let sortRaw = qp.get("sort") ?? "title"
            guard let sort = BookSortKey(rawValue: sortRaw) else { throw HTTPError(.badRequest) }
            let query = BooksQuery(
                q: qp.get("q"),
                sort: sort,
                page: max(1, qp.get("page", as: Int.self) ?? 1),
                per: min(200, max(1, qp.get("per", as: Int.self) ?? 100))
            )
            return try query.run(on: lib)
        }
        // 表紙画像（ETag + immutable キャッシュ・If-None-Match で 304）。
        api.get("libraries/:lib/books/:id/cover") { request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let url = coverURL(bundleURL: lib.bundleURL, bookID: row.id)
            guard let data = try? Data(contentsOf: url) else { throw HTTPError(.notFound) }
            return cacheableImageResponse(data: data, etag: bookETag(for: row), request: request)
        }
        // 本のマニフェスト（ページ数・方向・形式・ETag）。
        api.get("libraries/:lib/books/:id/manifest") { request, context in
            let (_, row) = try await resolver.resolveBook(request, context)
            let content = try BookContentFactory.make(for: row)
            let pageCount = try await content.pageCount
            return ManifestDTO(
                pageCount: pageCount,
                direction: row.pageDirection.map(directionString),
                format: formatString(BookCategory.classify(path: row.path ?? "")),
                etag: bookETag(for: row)
            )
        }
        // ページ画像（ハンドルキャッシュ経由・ETag + immutable）。
        // 範囲外 → 404 / 範囲内の描画失敗 → 500（BookContentError.renderFailed 分離・4.1a）。
        let contentCache = self.contentCache
        api.get("libraries/:lib/books/:id/pages/:n") { request, context in
            let (lib, row) = try await resolver.resolveBook(request, context)
            let n = try context.parameters.require("n", as: Int.self)
            let content = try await contentCache.content(for: row, libraryUUID: lib.uuid)
            do {
                let data = try await content.imageData(at: n)
                return cacheableImageResponse(
                    data: data,
                    etag: bookETag(for: row) + "-p\(n)",
                    request: request
                )
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

/// unlock 成功レスポンス（短命ライブラリトークン）。
struct UnlockReply: ResponseEncodable {
    let libraryToken: String
}

extension ServerCapabilities: ResponseEncodable {}
extension LibraryDTO: ResponseEncodable {}
extension BookPageDTO: ResponseEncodable {}
