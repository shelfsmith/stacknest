// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("DecodeTargetMath")
struct DecodeTargetMathTests {
    @Test func headroomAppliedWithoutClamping() {
        // longestEdge=1200pt * scale 1.5 = 1800px backing * 1.25 headroom = 2250 — inside [floor, ceiling].
        let size = DecodeTargetMath.decodeTargetMaxPixelSize(
            canvasSize: CGSize(width: 1200, height: 1200),
            backingScaleFactor: 1.5,
            isSpread: false
        )
        #expect(size == 2250)
    }

    @Test func spreadHalvesPerPageTargetVsSingle() {
        let canvas = CGSize(width: 2000, height: 1000)
        let single = DecodeTargetMath.decodeTargetMaxPixelSize(canvasSize: canvas, backingScaleFactor: 2, isSpread: false)
        let spread = DecodeTargetMath.decodeTargetMaxPixelSize(canvasSize: canvas, backingScaleFactor: 2, isSpread: true)
        // single: longestEdge = max(2000,1000) = 2000 -> backing 4000 -> headroom 5000
        #expect(single == 5000)
        // spread: perPageWidth = 1000, longestEdge = max(1000,1000) = 1000 -> backing 2000 -> headroom 2500
        #expect(spread == 2500)
        #expect(spread == single / 2)
    }

    @Test func ceilingClampsExtremelyLargeCanvas() {
        let size = DecodeTargetMath.decodeTargetMaxPixelSize(
            canvasSize: CGSize(width: 10000, height: 10000),
            backingScaleFactor: 2,
            isSpread: false
        )
        #expect(size == DecodeTargetMath.ceilingPixelSize)
    }

    @Test func floorClampsExtremelySmallCanvas() {
        let size = DecodeTargetMath.decodeTargetMaxPixelSize(
            canvasSize: CGSize(width: 100, height: 100),
            backingScaleFactor: 1,
            isSpread: false
        )
        #expect(size == DecodeTargetMath.floorPixelSize)
    }

    @Test func zeroCanvasSizeReturnsFallback() {
        let size = DecodeTargetMath.decodeTargetMaxPixelSize(canvasSize: .zero, backingScaleFactor: 2, isSpread: false)
        #expect(size == DecodeTargetMath.fallbackPixelSize)
    }

    @Test func invalidBackingScaleFactorReturnsFallback() {
        let size = DecodeTargetMath.decodeTargetMaxPixelSize(
            canvasSize: CGSize(width: 1000, height: 1000),
            backingScaleFactor: 0,
            isSpread: false
        )
        #expect(size == DecodeTargetMath.fallbackPixelSize)
    }

    @Test func nonFiniteCanvasSizeReturnsFallback() {
        let size = DecodeTargetMath.decodeTargetMaxPixelSize(
            canvasSize: CGSize(width: CGFloat.infinity, height: 1000),
            backingScaleFactor: 2,
            isSpread: false
        )
        #expect(size == DecodeTargetMath.fallbackPixelSize)
    }

    /// G18 C3 review Minor #4 (test hardening): 2000×1800 は spreadHalvesPerPageTargetVsSingle の
    /// 2000×1000 と違い、halve-then-max (誤: max(width,height) を先に取ってから半分にする) と
    /// max-then-halve (正: 幅だけ半分にしてから height と max を取る) を区別できる。
    /// 正しい実装では spread の longestEdge は height(1800) が支配的になり、単純な "single/2" にはならない。
    @Test func spreadUsesHeightWhenItDominatesHalvedWidth() {
        let canvas = CGSize(width: 2000, height: 1800)
        let single = DecodeTargetMath.decodeTargetMaxPixelSize(canvasSize: canvas, backingScaleFactor: 2, isSpread: false)
        let spread = DecodeTargetMath.decodeTargetMaxPixelSize(canvasSize: canvas, backingScaleFactor: 2, isSpread: true)
        // single: longestEdge = max(2000,1800) = 2000 -> backing 4000 -> headroom 5000
        #expect(single == 5000)
        // spread: perPageWidth = 1000, longestEdge = max(1000,1800) = 1800 (height dominates the
        // halved width) -> backing 3600 -> headroom 4500. A buggy "halve the max first" implementation
        // would instead compute max(2000,1800)/2 = 1000 -> backing 2000 -> headroom 2500.
        #expect(spread == 4500)
        #expect(spread != single / 2)
    }

    @Test func nanCanvasWidthReturnsFallback() {
        let size = DecodeTargetMath.decodeTargetMaxPixelSize(
            canvasSize: CGSize(width: CGFloat.nan, height: 1000),
            backingScaleFactor: 2,
            isSpread: false
        )
        #expect(size == DecodeTargetMath.fallbackPixelSize)
    }

    @Test func negativeCanvasSizeReturnsFallback() {
        let size = DecodeTargetMath.decodeTargetMaxPixelSize(
            canvasSize: CGSize(width: -100, height: 100),
            backingScaleFactor: 2,
            isSpread: false
        )
        #expect(size == DecodeTargetMath.fallbackPixelSize)
    }

    @Test func negativeBackingScaleFactorReturnsFallback() {
        let size = DecodeTargetMath.decodeTargetMaxPixelSize(
            canvasSize: CGSize(width: 1000, height: 1000),
            backingScaleFactor: -2,
            isSpread: false
        )
        #expect(size == DecodeTargetMath.fallbackPixelSize)
    }

    @Test func nonFiniteBackingScaleFactorReturnsFallback() {
        let size = DecodeTargetMath.decodeTargetMaxPixelSize(
            canvasSize: CGSize(width: 1000, height: 1000),
            backingScaleFactor: CGFloat.infinity,
            isSpread: false
        )
        #expect(size == DecodeTargetMath.fallbackPixelSize)
    }
}
