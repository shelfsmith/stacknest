// SPDX-License-Identifier: MIT
import Foundation
import HTTPTypes
import Hummingbird

/// ロック庫の短命ライブラリトークン管理（メモリのみ・サーバ再起動で失効 — spec §4）。
actor LibraryTokenStore {
    private var tokens: [String: Set<String>] = [:]   // libraryUUID -> 有効トークン集合

    func issueToken(for libraryUUID: String) -> String {
        let token = UUID().uuidString + "-" + UUID().uuidString
        tokens[libraryUUID, default: []].insert(token)
        return token
    }

    func isValid(_ token: String, for libraryUUID: String) -> Bool {
        tokens[libraryUUID]?.contains(token) ?? false
    }
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
