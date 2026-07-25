// SPDX-License-Identifier: MIT
import Foundation
import AppCore

/// G23 (m4): grant の読み書きを 1 箇所へ集約する。
///
/// 従来は read が `config.grantsProvider`、write が `GrantStore`（UserDefaults.standard）直接
/// という非対称だった。テストは固定配列を read させつつ write は実 UserDefaults へ飛ぶため、
/// **CRUD が永続化に反映されたかを検証できなかった**。両方をこのプロトコル経由にすると、
/// テストでインメモリ実装を注入して読み書きの一貫性まで確認できる。
public protocol GrantRepository: Sendable {
    func all() -> [Grant]
    /// 同じ id が既にあれば置換、無ければ追加する。
    func upsert(_ grant: Grant)
    func delete(id: String)
}

/// 本番実装。既存の `GrantStore`（static API）を包む。
///
/// `@unchecked Sendable`: `UserDefaults` は `Sendable` に適合していないが、
/// [Apple のドキュメント](https://developer.apple.com/documentation/foundation/userdefaults)の
/// とおりスレッドセーフであり、本型は参照を保持して読み書きを委譲するだけで自前の可変状態を持たない。
public struct UserDefaultsGrantRepository: GrantRepository, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func all() -> [Grant] { GrantStore.list(defaults: defaults) }

    public func upsert(_ grant: Grant) {
        if GrantStore.list(defaults: defaults).contains(where: { $0.id == grant.id }) {
            GrantStore.update(grant, defaults: defaults)
        } else {
            GrantStore.add(grant, defaults: defaults)
        }
    }

    public func delete(id: String) { GrantStore.delete(id: id, defaults: defaults) }
}

/// テスト用のインメモリ実装。
///
/// `@unchecked Sendable`: 可変状態 `grants` への出入りをすべて `NSLock` で直列化しているため
/// データ競合は起きないが、コンパイラはそれを検証できない。
public final class InMemoryGrantRepository: GrantRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [Grant]

    public init(initial: [Grant]) { self.grants = initial }

    public func all() -> [Grant] { lock.withLock { grants } }

    public func upsert(_ grant: Grant) {
        lock.withLock { grants = grants.filter { $0.id != grant.id } + [grant] }
    }

    public func delete(id: String) {
        lock.withLock { grants = grants.filter { $0.id != id } }
    }
}
