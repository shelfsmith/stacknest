// SPDX-License-Identifier: MIT
import Foundation
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

/// HTTP サーバ本体。Router 構築と Application 生成を担う。
/// AppKit / ImageIO / PDFKit を import しないこと（Linux 移植規律・spec §3.2）。
public struct LibraryServerCore: Sendable {
    public let config: LibraryServerConfig
    let dataSource: any LibraryServerDataSource
    /// ロック庫の短命トークン（メモリのみ・再起動で失効）。
    let tokenStore = LibraryTokenStore()

    public init(config: LibraryServerConfig, dataSource: any LibraryServerDataSource) {
        self.config = config
        self.dataSource = dataSource
    }

    public func buildApplication() -> some ApplicationProtocol {
        let router = Router()
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
        // books 一覧（仮実装: 空配列 — 本実装は Task 5）。ロック庫は X-Library-Token 必須。
        api.get("libraries/:lib/books") { request, context in
            let uuid = try context.parameters.require("lib")
            let libraryToken = request.headers[.init("X-Library-Token")!]
            guard let lib = try await resolver.resolve(uuid: uuid, libraryToken: libraryToken) else {
                throw HTTPError(.notFound)
            }
            _ = lib
            return [BookListItemDTO]()   // Task 5 で本実装
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

/// unlock 成功レスポンス（短命ライブラリトークン）。
struct UnlockReply: ResponseEncodable {
    let libraryToken: String
}

/// 一覧 1 件分の仮 DTO（Task 5 で本定義に差し替え）。
public struct BookListItemDTO: Codable, Sendable {}

extension ServerCapabilities: ResponseEncodable {}
extension LibraryDTO: ResponseEncodable {}
extension BookListItemDTO: ResponseEncodable {}
