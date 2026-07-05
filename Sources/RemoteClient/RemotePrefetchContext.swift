// SPDX-License-Identifier: MIT
import Foundation

/// リモート閲覧時にビューアへ注入する先読みフック（ローカル閲覧では nil）。
/// content 非依存の ViewerWindowController から、可視保護報告・tier3 判定を委譲する。
public struct RemotePrefetchContext: Sendable {
    public let reportActiveWindow: @Sendable (Set<Int>) -> Void   // pages→Key 写像し setProtected(owner:)
    public let clearProtection: @Sendable () -> Void              // ビューア閉/巻スワップで clearProtected(owner:)
    public let tier3Enabled: @Sendable () -> Bool                 // RemoteCacheSettings を読む
    public init(reportActiveWindow: @escaping @Sendable (Set<Int>) -> Void,
                clearProtection: @escaping @Sendable () -> Void,
                tier3Enabled: @escaping @Sendable () -> Bool) {
        self.reportActiveWindow = reportActiveWindow
        self.clearProtection = clearProtection
        self.tier3Enabled = tier3Enabled
    }
}
