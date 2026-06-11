// SPDX-License-Identifier: MIT
import Foundation
import Hummingbird

/// Bearer トークン認証。比較は定数時間（タイミング攻撃対策・spec §4）。
///
/// セキュリティ注記: `Authorization: Bearer` ヘッダが無い場合に限り `?token=<t>` クエリを
/// fallback として受理する。`<img>`/`<video>` はカスタムヘッダを送れないための妥協で、
/// トークンが URL/サーバログに残る。トークンは LAN 用・再生成可能・既に QR/localStorage に
/// 存在するため許容する（ヘッダ優先・クエリは fallback）。
struct BearerAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: String

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let presented: String?
        if let header = request.headers[.authorization], header.hasPrefix("Bearer ") {
            presented = String(header.dropFirst("Bearer ".count))   // ヘッダ優先
        } else {
            presented = request.uri.queryParameters.get("token")    // fallback（<img> 用）
        }
        guard let presented, constantTimeEquals(presented, token) else {
            throw HTTPError(.unauthorized)
        }
        return try await next(request, context)
    }

    /// 長さが異なっても全バイト走査する定数時間比較。
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8), bBytes = Array(b.utf8)
        var diff = aBytes.count ^ bBytes.count
        for i in 0..<max(aBytes.count, bBytes.count) {
            let x = i < aBytes.count ? aBytes[i] : 0
            let y = i < bBytes.count ? bBytes[i] : 0
            diff |= Int(x ^ y)
        }
        return diff == 0
    }
}
