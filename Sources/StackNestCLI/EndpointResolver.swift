// SPDX-License-Identifier: MIT
import Foundation

public struct ResolvedEndpoint: Equatable {
    public let baseURL: String   // 末尾スラッシュ無し
    public let token: String
}

/// 接続先解決: --url/--token > 環境変数 > アプリ既定(127.0.0.1:port + token)。token 空なら nil。
public enum EndpointResolver {
    public static func resolve(urlArg: String?, tokenArg: String?,
                               env: [String: String],
                               defaultsPort: Int, defaultsToken: String) -> ResolvedEndpoint? {
        let url = urlArg ?? env["STACKNEST_URL"]
            ?? (defaultsPort > 0 ? "http://127.0.0.1:\(defaultsPort)" : nil)
        let token = tokenArg ?? env["STACKNEST_TOKEN"]
            ?? (defaultsToken.isEmpty ? nil : defaultsToken)
        guard let url, let token, !token.isEmpty else { return nil }
        return ResolvedEndpoint(baseURL: url.hasSuffix("/") ? String(url.dropLast()) : url, token: token)
    }
}
