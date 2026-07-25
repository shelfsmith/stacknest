// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import Hummingbird
import LibraryServerAPI

/// Bearer トークン認証。比較は定数時間（タイミング攻撃対策・spec §4）。
/// R トークン（読み取り）と RW トークン（編集）の双方を受理し、提示トークンに応じて
/// context.role / context.tier を刻む（RW ゲートは下流ハンドラが role/tier を見て判断する・4.2b-3・B1）。
///
/// adminTier=true のとき: R/W いずれのトークンも admin tier（role=write）として扱う（LAN 信頼環境向け）。
/// adminTier=false のとき: R → read tier、W → edit tier。
///
/// セキュリティ注記: `Authorization: Bearer` ヘッダが無い場合に限り `?token=<t>` クエリを
/// fallback として受理する。`<img>`/`<video>` はカスタムヘッダを送れないための妥協で、
/// トークンが URL/サーバログに残る。トークンは LAN 用・再生成可能・既に QR/localStorage に
/// 存在するため許容する（ヘッダ優先・クエリは fallback）。R/RW いずれも同じコードパスで受理する。
struct BearerAuthMiddleware<Context: RequestContext & RoleHoldingContext>: RouterMiddleware {
    let token: String
    let editToken: String?
    let adminTier: Bool
    /// グラント解決クロージャ（毎リクエスト現在値を返す＝ライブ反映・C-③a）。
    /// nil = 旧来の token/editToken 直接照合パス（テスト/ローカルコントロール adminTier 用）。
    let grantsProvider: (@Sendable () -> [Grant])?
    /// G23 (#9/#10): クエリに載る短命セッショントークンの解決先。
    let sessionTokenStore: SessionTokenStore

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let presented: String?
        if let header = request.headers[.authorization], header.hasPrefix("Bearer ") {
            presented = String(header.dropFirst("Bearer ".count))   // ヘッダ優先
        } else if let rawQueryToken = request.uri.queryParameters.get("token") {
            let queryToken = String(rawQueryToken)
            // G23 (#9/#10): クエリに載るのは短命セッショントークン。
            // 解決できなければ、従来どおり grant token 直挿しとして扱う（既存クライアント互換）。
            presented = await sessionTokenStore.resolve(queryToken) ?? queryToken
        } else {
            presented = nil
        }
        guard let presented else { throw HTTPError(.unauthorized) }
        var ctx = context
        if let grantsProvider {
            // グラントモード（ライブ）: 毎リクエスト現在のグラントを取得し照合、tier/scope を刻む。
            // 削除済みグラント＝マッチなし＝401＝即時失効。
            let grants = grantsProvider()
            guard let g = grants.first(where: { constantTimeEquals(presented, $0.token) }) else {
                throw HTTPError(.unauthorized)
            }
            ctx.tier = g.tier
            ctx.scope = g.scope
            ctx.role = (g.tier == .read) ? .read : .write
            // G23 (M3): unlock のレート制限を principal 単位にするための識別子。
            // トークンの生値ではなく grant の id を使う（ログや状態に秘密を残さない）。
            ctx.grantID = g.id
        } else if adminTier {
            // adminTier モード: R/W いずれかのトークンが一致すれば admin 昇格。
            if constantTimeEquals(presented, token) || (editToken.map { constantTimeEquals(presented, $0) } ?? false) {
                ctx.role = .write; ctx.tier = .admin; ctx.scope = .all
            } else { throw HTTPError(.unauthorized) }
        } else if constantTimeEquals(presented, token) {
            ctx.role = .read; ctx.tier = .read; ctx.scope = .all
        } else if let editToken, constantTimeEquals(presented, editToken) {
            ctx.role = .write; ctx.tier = .edit; ctx.scope = .all
        } else {
            throw HTTPError(.unauthorized)
        }
        return try await next(request, ctx)
    }
}

/// 長さが異なっても全バイト走査する定数時間比較。
/// BearerAuthMiddleware と /events の長寿命接続再検証（liveConnectionStillAuthorized）の双方から
/// 共有するためファイルスコープ関数として公開する（タイミング攻撃対策・spec §4）。
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8), bBytes = Array(b.utf8)
    var diff = aBytes.count ^ bBytes.count
    for i in 0..<max(aBytes.count, bBytes.count) {
        let x = i < aBytes.count ? aBytes[i] : 0
        let y = i < bBytes.count ? bBytes[i] : 0
        diff |= Int(x ^ y)
    }
    return diff == 0
}

/// SSE 長寿命接続の再認証: 提示トークンに一致する grant が現存し、その scope が接続時 scope と一致するか。
/// grants に一致トークンが無い＝失効、scope が変わった＝再接続で更新すべき → いずれも false。
func liveConnectionStillAuthorized(presentedToken: String, subscribedScope: GrantScope, grants: [Grant]) -> Bool {
    guard let g = grants.first(where: { constantTimeEquals(presentedToken, $0.token) }) else { return false }
    return g.scope == subscribedScope
}
