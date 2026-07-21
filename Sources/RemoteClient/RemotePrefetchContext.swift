// SPDX-License-Identifier: MIT
import Foundation

/// リモート閲覧時にビューアへ注入する先読みフック（ローカル閲覧では nil）。
/// content 非依存の ViewerWindowController から、可視保護報告・tier3 判定を委譲する。
public struct RemotePrefetchContext: Sendable {
    /// (可視ページ集合, 現在のリモート bookID, その本の版トークン=manifest.etag)。
    /// bookID/version は巻スワップ追従のためビューアが都度渡す（C1／G4d 層2）。version は
    /// RemotePageCache.Key の版キーと一致させ、可視保護（setProtected）が実際のページ
    /// キャッシュエントリを正しく引き当てるために必要（不一致だと保護が空振りする）。
    public let reportActiveWindow: @Sendable (Set<Int>, Int?, String?) -> Void   // pages→Key 写像し setProtected(owner:)
    public let clearProtection: @Sendable () -> Void                    // ビューア閉/巻スワップで clearProtected(owner:)
    public let tier3Enabled: @Sendable () -> Bool                       // RemoteCacheSettings を読む
    /// 現在 (bookID, version) → その本の L2 キャッシュ済みページ集合（プログレスバー可視化用・~1s ポーリング）。
    /// レビュー Important1 fix: version も渡す（呼び出し側が現在表示中の版を都度渡す）。version を
    /// 渡さず版無視で数えると、relink 直後は旧版の行がまだ disk に残っていて「キャッシュ済み」と
    /// 誤って数えてしまう（実際は全ページがミスして再取得される）。
    public let cachedPages: @Sendable (Int, String?) async -> Set<Int>
    public init(reportActiveWindow: @escaping @Sendable (Set<Int>, Int?, String?) -> Void,
                clearProtection: @escaping @Sendable () -> Void,
                tier3Enabled: @escaping @Sendable () -> Bool,
                cachedPages: @escaping @Sendable (Int, String?) async -> Set<Int>) {
        self.reportActiveWindow = reportActiveWindow
        self.clearProtection = clearProtection
        self.tier3Enabled = tier3Enabled
        self.cachedPages = cachedPages
    }
}

/// 可視保護の更新（setProtected/clearProtected）を発行順に直列化するための Task チェーン保持箱。
/// 発行は単一の MainActor 文脈（recompute/close）からのみ行う前提のため @unchecked Sendable。
public final class ProtectionChain: @unchecked Sendable {
    public var task: Task<Void, Never>?
    public init() {}
}
