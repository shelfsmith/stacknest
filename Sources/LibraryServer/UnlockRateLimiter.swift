// SPDX-License-Identifier: MIT
import Foundation

/// #2: ロック庫 unlock のブルートフォース抑止。
///
/// ライブラリ UUID ごとに連続失敗回数を数え、`maxFailures` に達したら `lockoutSeconds` の間
/// unlock を一律拒否する（429）。成功でカウンタをリセットする。プロセス内メモリのみ（Tailscale 前提・
/// サーバ再起動でリセットされる程度の抑止で十分）。`now` は注入可能でテスト容易性を確保する。
public actor UnlockRateLimiter {
    private struct State { var count: Int; var lockedUntil: Date? }
    private var byLibrary: [String: State] = [:]

    public let maxFailures: Int
    public let lockoutSeconds: TimeInterval

    public init(maxFailures: Int = 5, lockoutSeconds: TimeInterval = 30) {
        self.maxFailures = maxFailures
        self.lockoutSeconds = lockoutSeconds
    }

    /// 現在ロックアウト中か（true = unlock を拒否すべき）。期限切れロックは掃除する。
    public func isLockedOut(_ uuid: String, now: Date = Date()) -> Bool {
        guard let st = byLibrary[uuid], let until = st.lockedUntil else { return false }
        if now < until { return true }
        // 期限切れ: カウンタをリセットして再挑戦を許す。
        byLibrary[uuid] = nil
        return false
    }

    /// パスワード不一致を記録する。閾値に達したらロックアウト期限を設定する。
    public func recordFailure(_ uuid: String, now: Date = Date()) {
        var st = byLibrary[uuid] ?? State(count: 0, lockedUntil: nil)
        // 期限切れロックが残っていれば作り直す。
        if let until = st.lockedUntil, now >= until { st = State(count: 0, lockedUntil: nil) }
        st.count += 1
        if st.count >= maxFailures { st.lockedUntil = now.addingTimeInterval(lockoutSeconds) }
        byLibrary[uuid] = st
    }

    /// unlock 成功: そのライブラリのカウンタ／ロックを解除する。
    public func recordSuccess(_ uuid: String) {
        byLibrary[uuid] = nil
    }
}
