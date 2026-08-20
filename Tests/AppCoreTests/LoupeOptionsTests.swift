// SPDX-License-Identifier: MIT
import Testing
import CoreGraphics
@testable import AppCore

@Suite("ルーペの倍率（G40）")
struct LoupeMagnificationTests {
    @Test func clampKeepsValuesInsideTheRange() {
        #expect(LoupeMagnification.clamp(2.0) == 2.0)
        #expect(LoupeMagnification.clamp(1.0) == LoupeMagnification.range.lowerBound)
        #expect(LoupeMagnification.clamp(99) == LoupeMagnification.range.upperBound)
    }

    /// 壊れた値で NaN を持ち回ると、`loupeSource` の矩形計算まで汚染される。既定へ畳む。
    @Test func clampFoldsBrokenValuesToTheDefault() {
        #expect(LoupeMagnification.clamp(.nan) == LoupeMagnification.defaultValue)
        #expect(LoupeMagnification.clamp(.infinity) == LoupeMagnification.defaultValue)
        #expect(LoupeMagnification.clamp(0) == LoupeMagnification.range.lowerBound)
        #expect(LoupeMagnification.clamp(-5) == LoupeMagnification.range.lowerBound)
    }

    /// 乗算で動かす。加算だと低倍率側が粗く高倍率側が細かくなり体感が破綻する。
    /// 「2 倍から 1 段上げた量」と「4 倍から 1 段上げた量」の**比**が等しいことで確かめる。
    @Test func stepsMultiplicativelyNotAdditively() {
        let a = LoupeMagnification.stepped(from: 2.0, scrollDeltaY: 10, hasPreciseDeltas: false)
        let b = LoupeMagnification.stepped(from: 4.0, scrollDeltaY: 10, hasPreciseDeltas: false)
        #expect(abs((a / 2.0) - (b / 4.0)) < 0.0001, "同じスクロール量なら同じ倍率比で動く")
    }

    @Test func scrollingUpIncreasesAndDownDecreases() {
        #expect(LoupeMagnification.stepped(from: 2.0, scrollDeltaY: 10, hasPreciseDeltas: false) > 2.0)
        #expect(LoupeMagnification.stepped(from: 2.0, scrollDeltaY: -10, hasPreciseDeltas: false) < 2.0)
    }

    @Test func saturatesAtBothEnds() {
        var v = LoupeMagnification.range.upperBound
        for _ in 0..<50 { v = LoupeMagnification.stepped(from: v, scrollDeltaY: 10, hasPreciseDeltas: false) }
        #expect(v == LoupeMagnification.range.upperBound)

        v = LoupeMagnification.range.lowerBound
        for _ in 0..<50 { v = LoupeMagnification.stepped(from: v, scrollDeltaY: -10, hasPreciseDeltas: false) }
        #expect(v == LoupeMagnification.range.lowerBound)
    }

    /// トラックパッド（precise）は同じ生の delta でも**細かく**動く。
    /// そうしないと、連続値が毎フレーム来るトラックパッドで倍率が跳ぶ。
    @Test func preciseDeltasMoveLessPerUnit() {
        let precise = LoupeMagnification.stepped(from: 2.0, scrollDeltaY: 10, hasPreciseDeltas: true)
        let notched = LoupeMagnification.stepped(from: 2.0, scrollDeltaY: 10, hasPreciseDeltas: false)
        #expect(precise > 2.0)
        #expect(precise < notched, "precise の方が 1 単位あたりの変化が小さい")
    }

    @Test func brokenDeltasLeaveTheValueAlone() {
        #expect(LoupeMagnification.stepped(from: 3.0, scrollDeltaY: .nan, hasPreciseDeltas: false) == 3.0)
        #expect(LoupeMagnification.stepped(from: 3.0, scrollDeltaY: 0, hasPreciseDeltas: false) == 3.0)
    }

    /// `exp` の合成則そのものを確かめる: 同じ delta を半分ずつ 2 回適用した結果は、
    /// 一度に全部適用した結果と一致するはず（exp(a)*exp(a) == exp(2a)）。
    /// `exp` を線形近似（`1 + x`）に置き換えても `stepsMultiplicativelyNotAdditively` は
    /// 通ってしまう（どちらも current に対して乗算的なので）ため、指数関数であること自体を
    /// 直接検証する必要がある。
    @Test func composesAcrossStepsLikeAnExponential() {
        let full = LoupeMagnification.stepped(from: 2.0, scrollDeltaY: 20, hasPreciseDeltas: false)
        let halfHalf = LoupeMagnification.stepped(
            from: LoupeMagnification.stepped(from: 2.0, scrollDeltaY: 10, hasPreciseDeltas: false),
            scrollDeltaY: 10,
            hasPreciseDeltas: false
        )
        #expect(abs(full - halfHalf) < 0.0001, "2 回に分けても 1 回でも同じ倍率になる（指数の合成則）")
    }
}

@Suite("ルーペの形状（G40）")
struct LoupeShapeTests {
    @Test func defaultsToCircle() { #expect(LoupeShape.defaultValue == .circle) }

    @Test func everyCaseHasADisplayName() {
        for s in LoupeShape.allCases { #expect(!s.displayName.isEmpty) }
    }

    /// 設定に保存するので rawValue を勝手に変えてはいけない（保存済みの設定が読めなくなる）。
    @Test func rawValuesAreStable() {
        #expect(LoupeShape.circle.rawValue == "circle")
        #expect(LoupeShape.square.rawValue == "square")
    }
}
