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
    private struct State {
        var count: Int
        var lockedUntil: Date?
        /// G23 Codex High #2: 検証中（actor 外で PBKDF2 を回している）試行の数。
        /// 失敗が記録される前のゲート通過を数えるために必要。
        var inFlight: Int = 0
    }
    private struct Key: Hashable { let library: String; let principal: String }
    private var states: [Key: State] = [:]

    public let maxFailures: Int
    public let lockoutSeconds: TimeInterval
    /// 同一 principal が同時に検証へ入れる上限。PBKDF2 は意図的に重いので、
    /// 並行数を絞らないとレート制限とは別に CPU 枯渇攻撃が成立する。
    public let maxConcurrentAttempts: Int

    public init(maxFailures: Int = 5, lockoutSeconds: TimeInterval = 30,
                maxConcurrentAttempts: Int = 2) {
        self.maxFailures = maxFailures
        self.lockoutSeconds = lockoutSeconds
        self.maxConcurrentAttempts = maxConcurrentAttempts
    }

    /// 試行枠の予約結果。
    public enum AttemptPermit: Equatable, Sendable {
        case granted
        /// ロックアウト中。`retryAfter` 秒後に再挑戦できる。
        case lockedOut(retryAfter: Int)
        /// 同時実行が多すぎる（検証中の試行が上限に達している）。
        case tooManyConcurrent(retryAfter: Int)
    }

    /// G23 Codex High #2: **ゲート判定と枠の確保を actor 内で原子的に行う**。
    ///
    /// 以前は `isLockedOut` → （actor 外で PBKDF2 検証）→ `recordFailure` の 3 段階だったため、
    /// 同一 principal から要求を同時送信すると**すべてが失敗記録前にゲートを通過**した。
    /// 閾値 5 回でも並行 100 要求なら 100 回の検証が走り、レート制限が実質無効になるうえ、
    /// PBKDF2 210,000 回 × 並行数の CPU を消費させられる。
    ///
    /// 予約した側は必ず `finishAttempt(_:principal:success:)` を呼ぶこと（defer 推奨）。
    public func beginAttempt(_ uuid: String, principal: String, now: Date = Date()) -> AttemptPermit {
        let key = Key(library: uuid, principal: principal)
        var st = states[key] ?? State(count: 0, lockedUntil: nil)
        // 期限切れロックは掃除してから判定する。
        if let until = st.lockedUntil, now >= until {
            st = State(count: 0, lockedUntil: nil, inFlight: st.inFlight)
        }
        if let until = st.lockedUntil, now < until {
            states[key] = st
            return .lockedOut(retryAfter: max(1, Int(until.timeIntervalSince(now).rounded(.up))))
        }
        // 検証中のものを含めて閾値に達しているなら、これ以上は通さない。
        if st.count + st.inFlight >= maxFailures {
            st.lockedUntil = now.addingTimeInterval(lockoutSeconds)
            states[key] = st
            return .lockedOut(retryAfter: Int(lockoutSeconds))
        }
        if st.inFlight >= maxConcurrentAttempts {
            states[key] = st
            return .tooManyConcurrent(retryAfter: 1)
        }
        st.inFlight += 1
        states[key] = st
        return .granted
    }

    /// 予約した試行の後始末。成功ならカウンタを消し、失敗なら加算する。
    public func finishAttempt(_ uuid: String, principal: String, success: Bool, now: Date = Date()) {
        let key = Key(library: uuid, principal: principal)
        guard var st = states[key] else { return }
        st.inFlight = max(0, st.inFlight - 1)
        if success {
            // 成功: この principal のカウンタ／ロックを解除する（in-flight は保持）。
            states[key] = st.inFlight > 0 ? State(count: 0, lockedUntil: nil, inFlight: st.inFlight) : nil
            return
        }
        st.count += 1
        if st.count >= maxFailures { st.lockedUntil = now.addingTimeInterval(lockoutSeconds) }
        states[key] = st
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
