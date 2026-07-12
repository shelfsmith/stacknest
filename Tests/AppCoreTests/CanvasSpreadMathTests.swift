// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("CanvasFitMath spread")
struct CanvasSpreadMathTests {
    @Test func twoEqualPortraitImagesFitWithGutter() {
        // 2 枚 50x100、view 100x100、gutter 0
        // totalWidth=100, maxHeight=100 → scaleW=100/100=1, scaleH=100/100=1 → s=1
        let images = [CGSize(width: 50, height: 100), CGSize(width: 50, height: 100)]
        let view = CGSize(width: 100, height: 100)
        let s = CanvasFitMath.spreadFitScale(images: images, viewSize: view, gutter: 0)
        #expect(abs(s - 1.0) < 0.0001)
        // 左→右自然順 (firstOnRight=false): [0] at x=0, [1] at x=50
        let rects = CanvasFitMath.spreadDrawRects(images: images, viewSize: view, scale: s, offset: .zero, gutter: 0, firstOnRight: false)
        #expect(rects.count == 2)
        #expect(rects[0] == CGRect(x: 0, y: 0, width: 50, height: 100))
        #expect(rects[1] == CGRect(x: 50, y: 0, width: 50, height: 100))
    }

    @Test func gutterReducesScaleAndShiftsRects() {
        // 2 枚 50x100、view 110x100、gutter 10
        // availableWidth=110-10=100, totalWidth=100 → scaleW=1; scaleH=100/100=1 → s=1
        // totalW = 50+50 + 10 = 110, startX=(110-110)/2=0; [0]@0..50, [1]@60..110
        let images = [CGSize(width: 50, height: 100), CGSize(width: 50, height: 100)]
        let view = CGSize(width: 110, height: 100)
        let s = CanvasFitMath.spreadFitScale(images: images, viewSize: view, gutter: 10)
        #expect(abs(s - 1.0) < 0.0001)
        let rects = CanvasFitMath.spreadDrawRects(images: images, viewSize: view, scale: s, offset: .zero, gutter: 10, firstOnRight: false)
        #expect(rects[0] == CGRect(x: 0, y: 0, width: 50, height: 100))
        #expect(rects[1] == CGRect(x: 60, y: 0, width: 50, height: 100))
    }

    @Test func firstOnRightSwapsXPositions() {
        // 同上だが firstOnRight=true → [1] が左 (x=0)、[0] が右 (x=50)
        let images = [CGSize(width: 50, height: 100), CGSize(width: 50, height: 100)]
        let view = CGSize(width: 100, height: 100)
        let rects = CanvasFitMath.spreadDrawRects(images: images, viewSize: view, scale: 1, offset: .zero, gutter: 0, firstOnRight: true)
        #expect(rects[1] == CGRect(x: 0, y: 0, width: 50, height: 100))
        #expect(rects[0] == CGRect(x: 50, y: 0, width: 50, height: 100))
    }

    @Test func singleImageEqualsSingleFit() {
        // 1 枚 200x100、view 100x100、gutter 0 → fitScale と一致 (0.5)
        let images = [CGSize(width: 200, height: 100)]
        let view = CGSize(width: 100, height: 100)
        let s = CanvasFitMath.spreadFitScale(images: images, viewSize: view, gutter: 0)
        let single = CanvasFitMath.fitScale(imageSize: CGSize(width: 200, height: 100), viewSize: view)
        #expect(abs(s - single) < 0.0001)
        // 矩形は単独中央配置: 200*0.5=100, 100*0.5=50, y=(100-50)/2=25
        let rects = CanvasFitMath.spreadDrawRects(images: images, viewSize: view, scale: s, offset: .zero, gutter: 0, firstOnRight: false)
        #expect(rects.count == 1)
        #expect(rects[0] == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func unequalWidthsFirstOnRightWithGutter() {
        // A=80x60, B=20x100, view 200x120, gutter 10 -> scale 1.2 (B height-bound)
        let images = [CGSize(width: 80, height: 60), CGSize(width: 20, height: 100)]
        let view = CGSize(width: 200, height: 120)
        let s = CanvasFitMath.spreadFitScale(images: images, viewSize: view, gutter: 10)
        #expect(abs(s - 1.2) < 0.0001)
        let r = CanvasFitMath.spreadDrawRects(images: images, viewSize: view, scale: s, offset: .zero, gutter: 10, firstOnRight: true)
        #expect(r[1] == CGRect(x: 35, y: 0, width: 24, height: 120))   // B left, full height
        #expect(r[0] == CGRect(x: 69, y: 24, width: 96, height: 72))   // A right, vertically centered
    }

    @Test func heightNormalizeEqualizesDifferentResolutionSameAspect() {
        // Artiste バグ: 同一アスペクト比・異解像度の 2 枚（1131x1608 低解像度 と 1351x1920 高解像度）は
        // 見開きで同じ表示高さになるべき（低解像度側だけ小さく描画されない）。
        let a = CGSize(width: 1131, height: 1608)  // 低解像度
        let b = CGSize(width: 1351, height: 1920)  // 高解像度
        let norm = CanvasFitMath.heightNormalized([a, b])
        #expect(norm.count == 2)
        // 高さが揃う
        #expect(abs(norm[0].height - norm[1].height) < 0.001)
        // アスペクト比は各画像で保存（歪まない）
        #expect(abs(norm[0].width / norm[0].height - a.width / a.height) < 0.001)
        #expect(abs(norm[1].width / norm[1].height - b.width / b.height) < 0.001)
        // 正規化後サイズで見開き配置 → 両ページの描画「高さ」が等しい（バグ時は異なる）
        let view = CGSize(width: 4000, height: 2000)
        let s = CanvasFitMath.spreadFitScale(images: norm, viewSize: view, gutter: 0)
        let rects = CanvasFitMath.spreadDrawRects(images: norm, viewSize: view, scale: s, offset: .zero, gutter: 0, firstOnRight: false)
        #expect(abs(rects[0].height - rects[1].height) < 0.001)
    }

    @Test func heightNormalizeSingleAndEmptyUnchanged() {
        #expect(CanvasFitMath.heightNormalized([]) == [])
        let one = [CGSize(width: 200, height: 100)]
        #expect(CanvasFitMath.heightNormalized(one) == one)
    }

    @Test func emptyArrayReturnsEmpty() {
        #expect(CanvasFitMath.spreadFitScale(images: [], viewSize: CGSize(width: 100, height: 100), gutter: 0) == 1)
        #expect(CanvasFitMath.spreadDrawRects(images: [], viewSize: CGSize(width: 100, height: 100), scale: 1, offset: .zero, gutter: 0, firstOnRight: false) == [])
    }
}
