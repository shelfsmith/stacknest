// SPDX-License-Identifier: MIT
import Foundation

/// 接続済みサーバ 1 件。token も含めて UserDefaults に平文保存する。
/// token を Keychain に入れないのは ADC 未登録環境で ad-hoc 署名のたびに
/// 「キーチェーンアクセス」prompt が再発するため（Phase 2.6g と同根）。
/// token は LAN 共有用の低価値シークレット（サーバ UI が平文表示・web は localStorage 平文）
/// であり、web クライアントと parity を取って平文保存を許容する。
public struct ServerConnection: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var displayName: String?
    public var baseURL: String   // "http://host:port/"
    public var token: String
    public init(id: UUID, displayName: String?, baseURL: String, token: String) {
        self.id = id; self.displayName = displayName; self.baseURL = baseURL; self.token = token
    }
}

/// 接続履歴を UserDefaults に平文でリスト永続化する。
public struct ServerConnectionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let listKey = "remote_server_connections"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func all() -> [ServerConnection] {
        guard let data = defaults.data(forKey: Self.listKey),
              let list = try? JSONDecoder().decode([ServerConnection].self, from: data) else { return [] }
        return list
    }

    public func connection(id: UUID) -> ServerConnection? {
        all().first { $0.id == id }
    }

    public func upsert(_ c: ServerConnection) {
        var list = all()
        if let i = list.firstIndex(where: { $0.id == c.id }) { list[i] = c } else { list.append(c) }
        persist(list)
    }

    public func remove(id: UUID) {
        persist(all().filter { $0.id != id })
    }

    private func persist(_ list: [ServerConnection]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.listKey)
    }
}
