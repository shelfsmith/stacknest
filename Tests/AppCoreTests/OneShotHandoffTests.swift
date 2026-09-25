// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G54-S3e（spec §2.1-6）: 巻送りの判定で取った manifest を、開く側へ 1 回だけ引き継ぐ。
/// 判定と開くときで 2 回取ると、2 回目だけ失敗して「窓を閉じた後に開けない」が起きる。
@Suite("G54-S3e: 1 回限りの引き継ぎ")
struct OneShotHandoffTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func sameIDWithinTheAgeIsHandedOnce() {
        var h = OneShotHandoff<String>(maxAge: 30)
        h.put(id: 7, value: "m", now: t0)
        #expect(h.take(id: 7, now: t0.addingTimeInterval(1)) == "m")
        #expect(h.take(id: 7, now: t0.addingTimeInterval(2)) == nil)
    }

    /// Review Focus 3: 別の本を開いたら何も渡さず、預かりも消す（後で元の本を開いても古いものは出ない）。
    @Test func anotherIDGetsNothingAndClears() {
        var h = OneShotHandoff<String>(maxAge: 30)
        h.put(id: 7, value: "m", now: t0)
        #expect(h.take(id: 8, now: t0) == nil)
        #expect(h.take(id: 7, now: t0) == nil)
    }

    /// Review Focus 3: 解決中に窓が閉じられて残った預かりを、時間が経ってから使わない。
    @Test func staleValueIsNotHanded() {
        var h = OneShotHandoff<String>(maxAge: 30)
        h.put(id: 7, value: "m", now: t0)
        #expect(h.take(id: 7, now: t0.addingTimeInterval(31)) == nil)
    }

    @Test func newerPutReplaces() {
        var h = OneShotHandoff<String>(maxAge: 30)
        h.put(id: 7, value: "old", now: t0)
        h.put(id: 7, value: "new", now: t0)
        #expect(h.take(id: 7, now: t0) == "new")
    }
}
