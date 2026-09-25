// SPDX-License-Identifier: MIT
import Foundation

/// G54-S3e（spec §2.1-6）: 判定のために取ったものを、直後に開く側へ **1 回だけ** 引き継ぐ（同じものを 2 回取らない）。
/// 本の ID と組にした 1 件だけを持つ。取り出すと、ID が一致してもしなくても消える。
/// `maxAge` を過ぎたものは渡さない — 解決中に窓が閉じられると預かりが残り、後で同じ本を一覧から開いたときに
/// 古い値（古い読書位置・etag）を使ってしまうため。
public struct OneShotHandoff<Value: Sendable>: Sendable {
    public let maxAge: TimeInterval
    private var id: Int?
    private var value: Value?
    private var storedAt: Date?

    public init(maxAge: TimeInterval = 30) {
        self.maxAge = maxAge
    }

    public mutating func put(id: Int, value: Value, now: Date = Date()) {
        self.id = id
        self.value = value
        self.storedAt = now
    }

    public mutating func take(id: Int, now: Date = Date()) -> Value? {
        defer {
            self.id = nil
            self.value = nil
            self.storedAt = nil
        }
        guard self.id == id, let value, let storedAt, now.timeIntervalSince(storedAt) <= maxAge else { return nil }
        return value
    }
}
