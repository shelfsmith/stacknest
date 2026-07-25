// SPDX-License-Identifier: MIT
import Foundation

/// #2: ロック庫 unlock のブルートフォース抑止。
///
/// **ライブラリ UUID ＋ principal**ごとに連続失敗回数を数え、`maxFailures` に達したら
/// `lockoutSeconds` の間 unlock を拒否する（429）。成功でカウンタをリセットする。
/// プロセス内メモリのみ（Tailscale 前提・サーバ再起動でリセットされる程度の抑止で十分）。
/// `now` は注入可能でテスト容易性を確保する。
///
/// G23 (M3): キーを library 単体から library＋principal へ変更した。
/// 単体だと、閲覧トークンを渡した相手が失敗を繰り返すだけで**正当な所有者を締め出せた**
/// （可用性攻撃）。principal は grant の id を用い、**トークンの生値は使わない**。
public actor UnlockRateLimiter {
    private struct State { var count: Int; var lockedUntil: Date? }
    private struct Key: Hashable { let library: String; let principal: String }
    private var states: [Key: State] = [:]

    public let maxFailures: Int
    public let lockoutSeconds: TimeInterval

    public init(maxFailures: Int = 5, lockoutSeconds: TimeInterval = 30) {
        self.maxFailures = maxFailures
        self.lockoutSeconds = lockoutSeconds
    }

    /// 現在ロックアウト中か（true = unlock を拒否すべき）。期限切れロックは掃除する。
    public func isLockedOut(_ uuid: String, principal: String, now: Date = Date()) -> Bool {
        let key = Key(library: uuid, principal: principal)
        guard let st = states[key], let until = st.lockedUntil else { return false }
        if now < until { return true }
        // 期限切れ: カウンタをリセットして再挑戦を許す。
        states[key] = nil
        return false
    }

    /// ロックアウト中なら残り秒（切り上げ・最低 1）を返す。非ロックアウトは nil。
    /// 429 応答の `Retry-After` に載せる。
    public func retryAfterSeconds(_ uuid: String, principal: String, now: Date = Date()) -> Int? {
        let key = Key(library: uuid, principal: principal)
        guard let st = states[key], let until = st.lockedUntil, now < until else { return nil }
        return max(1, Int(until.timeIntervalSince(now).rounded(.up)))
    }

    /// パスワード不一致を記録する。閾値に達したらロックアウト期限を設定する。
    public func recordFailure(_ uuid: String, principal: String, now: Date = Date()) {
        let key = Key(library: uuid, principal: principal)
        var st = states[key] ?? State(count: 0, lockedUntil: nil)
        // 期限切れロックが残っていれば作り直す。
        if let until = st.lockedUntil, now >= until { st = State(count: 0, lockedUntil: nil) }
        st.count += 1
        if st.count >= maxFailures { st.lockedUntil = now.addingTimeInterval(lockoutSeconds) }
        states[key] = st
    }

    /// unlock 成功: その principal のカウンタ／ロックを解除する（他の principal には触らない）。
    public func recordSuccess(_ uuid: String, principal: String) {
        states[Key(library: uuid, principal: principal)] = nil
    }
}
