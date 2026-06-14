// SPDX-License-Identifier: MIT
import Foundation
import Hummingbird
import LibraryServerAPI

/// Bearer トークン認証。比較は定数時間（タイミング攻撃対策・spec §4）。
/// R トークン（読み取り）と RW トークン（編集）の双方を受理し、提示トークンに応じて
/// context.role を read / write に刻む（RW ゲートは下流ハンドラが role を見て判断する・4.2b-3）。
///
/// セキュリティ注記: `Authorization: Bearer` ヘッダが無い場合に限り `?token=<t>` クエリを
/// fallback として受理する。`<img>`/`<video>` はカスタムヘッダを送れないための妥協で、
/// トークンが URL/サーバログに残る。トークンは LAN 用・再生成可能・既に QR/localStorage に
/// 存在するため許容する（ヘッダ優先・クエリは fallback）。R/RW いずれも同じコードパスで受理する。
struct BearerAuthMiddleware<Context: RequestContext & RoleHoldingContext>: RouterMiddleware {
    let token: String
    let editToken: String?

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
        guard let presented else { throw HTTPError(.unauthorized) }
        var ctx = context
        if constantTimeEquals(presented, token) {
            ctx.role = .read
        } else if let editToken, constantTimeEquals(presented, editToken) {
            ctx.role = .write
        } else {
            throw HTTPError(.unauthorized)
        }
        return try await next(request, ctx)
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
