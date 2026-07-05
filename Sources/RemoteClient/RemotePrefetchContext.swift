// SPDX-License-Identifier: MIT
import Foundation

/// リモート閲覧時にビューアへ注入する先読みフック（ローカル閲覧では nil）。
/// content 非依存の ViewerWindowController から、可視保護報告・tier3 判定を委譲する。
public struct RemotePrefetchContext: Sendable {
    /// (可視ページ集合, 現在のリモート bookID)。bookID は巻スワップ追従のためビューアが都度渡す（C1）。
    public let reportActiveWindow: @Sendable (Set<Int>, Int?) -> Void   // pages→Key 写像し setProtected(owner:)
    public let clearProtection: @Sendable () -> Void                    // ビューア閉/巻スワップで clearProtected(owner:)
    public let tier3Enabled: @Sendable () -> Bool                       // RemoteCacheSettings を読む
    public init(reportActiveWindow: @escaping @Sendable (Set<Int>, Int?) -> Void,
                clearProtection: @escaping @Sendable () -> Void,
                tier3Enabled: @escaping @Sendable () -> Bool) {
        self.reportActiveWindow = reportActiveWindow
        self.clearProtection = clearProtection
        self.tier3Enabled = tier3Enabled
    }
}

/// 可視保護の更新（setProtected/clearProtected）を発行順に直列化するための Task チェーン保持箱。
/// 発行は単一の MainActor 文脈（recompute/close）からのみ行う前提のため @unchecked Sendable。
public final class ProtectionChain: @unchecked Sendable {
    public var task: Task<Void, Never>?
    public init() {}
}
