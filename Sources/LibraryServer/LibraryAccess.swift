// SPDX-License-Identifier: MIT
import Foundation
import HTTPTypes
import Hummingbird
import LibraryServerAPI

/// ロック庫の短命ライブラリトークン管理（メモリのみ・サーバ再起動で失効 — spec §4）。
/// 加えて TTL（既定 24h・アクセスで延長しない単純期限 — 引き継ぎ(2)）で失効する。
actor LibraryTokenStore {
    /// G25d: `credential` は**発行時に認証した世代**（ロックハッシュ）。利用時に現行世代と突き合わせ、
    /// 一致しなければ失効させる。これが無いと、パスワード変更後も発行済みトークンが 24 時間有効なままになる。
    private struct Entry {
        let libraryUUID: String
        let credential: String
        let expiresAt: ContinuousClock.Instant
    }
    private var tokens: [String: Entry] = [:]   // token -> entry
    private let ttl: Duration
    private let clock = ContinuousClock()

    init(ttl: Duration = .seconds(60 * 60 * 24)) { self.ttl = ttl }

    /// G25d: `credential` には**認証に使った世代**を渡すこと（現在値ではない）。
    func issueToken(for libraryUUID: String, credential: String) -> String {
        tokens = tokens.filter { $0.value.expiresAt > clock.now }   // 期限切れ掃除
        let token = UUID().uuidString + "-" + UUID().uuidString
        tokens[token] = Entry(libraryUUID: libraryUUID, credential: credential, expiresAt: clock.now + ttl)
        return token
    }

    /// G25d: `currentCredential` は**利用時点の**ロックハッシュ。発行時の世代と一致しなければ無効。
    /// パスワードが変更（または解除）された時点で、発行済みトークンは自動的に失効する。
    func isValid(_ token: String, for libraryUUID: String, currentCredential: String?) -> Bool {
        guard let e = tokens[token], e.libraryUUID == libraryUUID else { return false }
        guard let current = currentCredential, current == e.credential else { return false }
        return e.expiresAt > clock.now
    }
}

/// ロック庫のライブラリトークンをリクエストから取り出す。
/// `X-Library-Token` ヘッダを優先し、無ければ `?lt=<libraryToken>` クエリを fallback とする。
/// セキュリティ注記: トークンが URL/サーバログに残るが、`<img>`/`<video>` がカスタムヘッダを
/// 送れないための妥協。短命・メモリのみ・再生成可能なので許容する（ヘッダ優先・クエリは fallback）。
func libraryToken(from request: Request) -> String? {
    if let header = request.headers[.init("X-Library-Token")!] { return header }
    return request.uri.queryParameters.get("lt")
}

/// ライブラリ解決 + ロックゲートの共通ヘルパ。
struct LibraryResolver: Sendable {
    let dataSource: any LibraryServerDataSource
    let tokenStore: LibraryTokenStore

    /// uuid からライブラリを引き、ロック庫なら X-Library-Token を検証する。
    /// 見つからない / スコープ外 → nil（404 相当）、ロック未解錠 → LibraryAccessError.locked（403）。
    func resolve(uuid: String, libraryToken: String?, scope: GrantScope = .all) async throws -> ServedLibrary? {
        guard scope.allows(uuid) else { return nil }
        guard let lib = await dataSource.servedLibraries().first(where: { $0.uuid == uuid }) else {
            return nil
        }
        if lib.isLocked {
            // G25d: 発行時に認証した世代が今も現行であることを要求する。
            guard let t = libraryToken,
                  await tokenStore.isValid(t, for: uuid, currentCredential: lib.currentLockCredential()) else {
                throw LibraryAccessError.locked
            }
        }
        return lib
    }
}

/// ロック庫アクセスエラー。HTTPResponseError 適合により router が自動で 403 を返す
/// （resolver を共有する全ルートハンドラで写像が効く）。
enum LibraryAccessError: Error, HTTPResponseError {
    case locked

    var status: HTTPResponse.Status {
        switch self {
        case .locked: .forbidden
        }
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        Response(status: status)
    }
}
