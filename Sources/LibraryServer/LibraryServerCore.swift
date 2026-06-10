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
    public init(config: LibraryServerConfig) {
        self.config = config
    }

    public func buildApplication() -> some ApplicationProtocol {
        let router = Router()
        router.get("/api/v1/server/info") { _, _ in
            ServerCapabilities.inApp
        }
        return Application(
            router: router,
            configuration: .init(address: .hostname(config.host, port: config.port))
        )
    }
}

extension ServerCapabilities: ResponseEncodable {}
