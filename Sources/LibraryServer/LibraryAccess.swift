// SPDX-License-Identifier: MIT
import Foundation
import HTTPTypes
import Hummingbird

/// ロック庫の短命ライブラリトークン管理（メモリのみ・サーバ再起動で失効 — spec §4）。
/// 加えて TTL（既定 24h・アクセスで延長しない単純期限 — 引き継ぎ(2)）で失効する。
actor LibraryTokenStore {
    private struct Entry { let libraryUUID: String; let expiresAt: ContinuousClock.Instant }
    private var tokens: [String: Entry] = [:]   // token -> entry
    private let ttl: Duration
    private let clock = ContinuousClock()

    init(ttl: Duration = .seconds(60 * 60 * 24)) { self.ttl = ttl }

    func issueToken(for libraryUUID: String) -> String {
        tokens = tokens.filter { $0.value.expiresAt > clock.now }   // 期限切れ掃除
        let token = UUID().uuidString + "-" + UUID().uuidString
        tokens[token] = Entry(libraryUUID: libraryUUID, expiresAt: clock.now + ttl)
        return token
    }

    func isValid(_ token: String, for libraryUUID: String) -> Bool {
        guard let e = tokens[token], e.libraryUUID == libraryUUID else { return false }
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
    /// 見つからない → nil（404 相当）、ロック未解錠 → LibraryAccessError.locked（403）。
    func resolve(uuid: String, libraryToken: String?) async throws -> ServedLibrary? {
        guard let lib = await dataSource.servedLibraries().first(where: { $0.uuid == uuid }) else {
            return nil
        }
        if lib.isLocked {
            guard let t = libraryToken, await tokenStore.isValid(t, for: uuid) else {
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
