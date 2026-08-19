// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G38: ルーペの拡大矩形計算。
///
/// 描画そのもの（`NSView.draw`）はテストしにくいが、**「カーソル位置から元画像のどの矩形を
/// 取るか」は純粋関数**なので完全に守れる。`CanvasFitMath` の既存関数と同じ流儀で置く。
///
/// **座標系:** ビューは `isFlipped == false`（原点左下・y 上向き）。
/// `CGImage` のピクセル座標は原点左上・y 下向きなので、`sourceRect` では y が反転する。
@Suite("ルーペの拡大矩形（G38）")
struct CanvasLoupeMathTests {

    /// 単ページ・等倍・オフセット無しの素直な条件。
    /// 画像 1000x2000、ビュー 500x1000 → fitScale 0.5 で画面いっぱい。
    private let img = CGSize(width: 1000, height: 2000)
    private let view = CGSize(width: 500, height: 1000)

    @Test("画像の中央にカーソルがあると、中央の矩形を取る")
    func centerOfImage() {
        let r = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)

        #expect(r.count == 1)
        let s = try! #require(r.first)
        #expect(s.imageIndex == 0)
        // 直径 100 を 2 倍で見る → 元画像上では 50 View pt 分。
        // scale 0.5 なので元画像のピクセルでは 50 / 0.5 = 100 px 四方。
        #expect(abs(s.sourceRect.width - 100) < 0.001)
        #expect(abs(s.sourceRect.height - 100) < 0.001)
        // 画像中央（ピクセル座標で 500, 1000）が矩形の中心
        #expect(abs(s.sourceRect.midX - 500) < 0.001)
        #expect(abs(s.sourceRect.midY - 1000) < 0.001)
    }

    @Test("倍率を上げると取る矩形が小さくなる")
    func higherMagnificationTakesSmallerRect() {
        let a = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)
        let b = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 4)

        let wa = try! #require(a.first).sourceRect.width
        let wb = try! #require(b.first).sourceRect.width
        #expect(wb < wa, "倍率 4 は倍率 2 より狭い範囲を取る")
        #expect(abs(wb * 2 - wa) < 0.001, "倍率が 2 倍なら取る幅は半分")
    }

    /// ★ ズーム中は実効倍率が `scale × magnification` になる。
    @Test("ズーム中は取る矩形がさらに小さくなる")
    func zoomedInTakesSmallerRect() {
        let fit = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)
        let zoomed = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 1.0, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)

        let wf = try! #require(fit.first).sourceRect.width
        let wz = try! #require(zoomed.first).sourceRect.width
        #expect(abs(wz * 2 - wf) < 0.001, "scale が 2 倍なら取る幅は半分")
    }

    /// ★ 画像の外にカーソルがあると何も返さない。
    @Test("画像の外では何も返さない")
    func outsideImageReturnsNothing() {
        // ビュー 500x1000 に対し画像は scale 0.5 で 500x1000 ＝ ぴったり。
        // offset で右へずらして左側に余白を作る。
        let r = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: CGSize(width: 900, height: 1000),
            scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 20, y: 500), loupeDiameter: 100, magnification: 2)
        #expect(r.isEmpty, "画像の左外にカーソルがあれば取るものが無い")
    }

    /// ★ 見開きのガターをまたぐと 2 枚から取る。
    @Test("見開きの境界をまたぐと 2 枚から取る")
    func acrossTheGutterTakesFromBothPages() {
        let two = [CGSize(width: 1000, height: 2000), CGSize(width: 1000, height: 2000)]
        // 2 枚が横に並ぶので合計 2000x2000。ビュー 1000x1000 なら fitScale 0.5。
        let r = CanvasFitMath.loupeSource(
            images: two, nativeSizes: two, viewSize: CGSize(width: 1000, height: 1000),
            scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 500, y: 500), loupeDiameter: 100, magnification: 2)

        #expect(r.count == 2, "境界の真上なら両ページから断片を取る")
        #expect(Set(r.map(\.imageIndex)) == Set([0, 1]))
    }

    /// ★ 解像度の違うページが混在する巻（実例: 1131x1608 と 1351x1920）。
    /// `images` は高さ正規化済みなので、`sourceRect` は**実ピクセル座標**で返らねばならない。
    /// これを取り違えると `CGImage.cropping(to:)` が誤った領域を切り出す。
    @Test("解像度が混在しても sourceRect は実ピクセル座標で返る")
    func mixedResolutionUsesNativePixels() {
        // 実寸 500x1000 の画像を、正規化で 1000x2000 相当に引き伸ばして配置している状況。
        let native = CGSize(width: 500, height: 1000)
        let normalized = CGSize(width: 1000, height: 2000)

        let r = CanvasFitMath.loupeSource(
            images: [normalized], nativeSizes: [native],
            viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)

        let s = try! #require(r.first)
        // 正規化座標なら 100px 四方だが、実寸は半分なので 50px 四方でなければならない
        #expect(abs(s.sourceRect.width - 50) < 0.001, "実ピクセル寸法へ換算されること")
        #expect(abs(s.sourceRect.height - 50) < 0.001)
        // 中心は実寸の中央（250, 500）
        #expect(abs(s.sourceRect.midX - 250) < 0.001)
        #expect(abs(s.sourceRect.midY - 500) < 0.001)
        // 実画像の外へはみ出していない
        #expect(s.sourceRect.minX >= -0.001 && s.sourceRect.maxX <= native.width + 0.001)
        #expect(s.sourceRect.minY >= -0.001 && s.sourceRect.maxY <= native.height + 0.001)
    }

    @Test("画像が無ければ何も返さない")
    func noImagesReturnsNothing() {
        let r = CanvasFitMath.loupeSource(
            images: [], nativeSizes: [], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)
        #expect(r.isEmpty)
    }

    /// パンしていてもカーソル下の内容が正しく取れる。
    @Test("パン中でもカーソル下の内容を取る")
    func panningShiftsTheSourceRect() {
        let noPan = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)
        let panned = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: CGSize(width: 50, height: 0),
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)

        let a = try! #require(noPan.first).sourceRect
        let b = try! #require(panned.first).sourceRect
        // 画像が右へ 50 pt 動いた＝同じカーソル位置は画像の左寄りを指す。
        // scale 0.5 なので元画像では 100 px 分。
        #expect(abs((a.midX - b.midX) - 100) < 0.001)
    }
}
