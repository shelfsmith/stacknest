// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("CanvasFitMath")
struct CanvasFitMathTests {
    @Test func fitScaleWideImageConstrainedByWidth() {
        let s = CanvasFitMath.fitScale(imageSize: CGSize(width: 200, height: 100), viewSize: CGSize(width: 100, height: 100))
        #expect(abs(s - 0.5) < 0.0001)
    }
    @Test func fitScaleTallImageConstrainedByHeight() {
        let s = CanvasFitMath.fitScale(imageSize: CGSize(width: 100, height: 200), viewSize: CGSize(width: 100, height: 100))
        #expect(abs(s - 0.5) < 0.0001)
    }
    @Test func fitScaleUpscalesSmallImage() {
        let s = CanvasFitMath.fitScale(imageSize: CGSize(width: 50, height: 50), viewSize: CGSize(width: 100, height: 100))
        #expect(abs(s - 2.0) < 0.0001)
    }
    @Test func fitScaleZeroSizeReturnsOne() {
        #expect(CanvasFitMath.fitScale(imageSize: .zero, viewSize: CGSize(width: 100, height: 100)) == 1)
        #expect(CanvasFitMath.fitScale(imageSize: CGSize(width: 100, height: 100), viewSize: .zero) == 1)
    }
    @Test func clampScaleBelowFitClampsToFit() {
        #expect(CanvasFitMath.clampScale(0.1, fitScale: 0.5, maxZoomFactor: 8) == 0.5)
    }
    @Test func clampScaleAboveMaxClampsToMax() {
        #expect(CanvasFitMath.clampScale(100, fitScale: 0.5, maxZoomFactor: 8) == 4.0)
    }
    @Test func clampScaleWithinRangeUnchanged() {
        #expect(CanvasFitMath.clampScale(1.0, fitScale: 0.5, maxZoomFactor: 8) == 1.0)
    }
    @Test func clampOffsetWithinBounds() {
        let o = CanvasFitMath.clampOffset(CGSize(width: 30, height: -40), scaledImageSize: CGSize(width: 200, height: 200), viewSize: CGSize(width: 100, height: 100))
        #expect(o == CGSize(width: 30, height: -40))
    }
    @Test func clampOffsetBeyondBoundsClamped() {
        let o = CanvasFitMath.clampOffset(CGSize(width: 999, height: -999), scaledImageSize: CGSize(width: 200, height: 200), viewSize: CGSize(width: 100, height: 100))
        #expect(o == CGSize(width: 50, height: -50))
    }
    @Test func clampOffsetImageSmallerThanViewIsZero() {
        let o = CanvasFitMath.clampOffset(CGSize(width: 30, height: 30), scaledImageSize: CGSize(width: 80, height: 80), viewSize: CGSize(width: 100, height: 100))
        #expect(o == .zero)
    }

    // MARK: imageDrawRect

    @Test func imageDrawRectCenteredAtScaleOne() {
        let r = CanvasFitMath.imageDrawRect(imageSize: CGSize(width: 40, height: 20), viewSize: CGSize(width: 100, height: 100), scale: 1, offset: .zero)
        #expect(r == CGRect(x: 30, y: 40, width: 40, height: 20))
    }
    @Test func imageDrawRectScalesAndStaysCentered() {
        let r = CanvasFitMath.imageDrawRect(imageSize: CGSize(width: 40, height: 20), viewSize: CGSize(width: 100, height: 100), scale: 2, offset: .zero)
        #expect(r == CGRect(x: 10, y: 30, width: 80, height: 40))
    }
    @Test func imageDrawRectAppliesOffset() {
        let r = CanvasFitMath.imageDrawRect(imageSize: CGSize(width: 40, height: 20), viewSize: CGSize(width: 100, height: 100), scale: 1, offset: CGSize(width: 5, height: -7))
        #expect(r == CGRect(x: 35, y: 33, width: 40, height: 20))
    }
    @Test func imageDrawRectZeroImageIsZero() {
        let r = CanvasFitMath.imageDrawRect(imageSize: .zero, viewSize: CGSize(width: 100, height: 100), scale: 2, offset: .zero)
        #expect(r == .zero)
    }
    @Test func imageDrawRectFitScaleFillsOneAxis() {
        // 200x100 image into 100x100 view: fitScale = 0.5 -> 100x50 centered.
        let fit = CanvasFitMath.fitScale(imageSize: CGSize(width: 200, height: 100), viewSize: CGSize(width: 100, height: 100))
        let r = CanvasFitMath.imageDrawRect(imageSize: CGSize(width: 200, height: 100), viewSize: CGSize(width: 100, height: 100), scale: fit, offset: .zero)
        #expect(r == CGRect(x: 0, y: 25, width: 100, height: 50))
    }
}
