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
        api.get("libraries") { _, _ in
            let libs = await dataSource.servedLibraries()
            return libs.map {
                LibraryDTO(id: $0.uuid, name: $0.name, locked: $0.isLocked,
                           bookCount: (try? $0.db.fetchBookCount()) ?? 0)
            }
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

extension ServerCapabilities: ResponseEncodable {}
extension LibraryDTO: ResponseEncodable {}
