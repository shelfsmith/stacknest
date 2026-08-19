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
    func centerOfImage() throws {
        let r = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)

        #expect(r.count == 1)
        let s = try #require(r.first)
        #expect(s.imageIndex == 0)
        // 直径 100 を 2 倍で見る → 元画像上では 50 View pt 分。
        // scale 0.5 なので元画像のピクセルでは 50 / 0.5 = 100 px 四方。
        #expect(abs(s.sourceRect.width - 100) < 0.001)
        #expect(abs(s.sourceRect.height - 100) < 0.001)
        // 画像中央（ピクセル座標で 500, 1000）が矩形の中心
        #expect(abs(s.sourceRect.midX - 500) < 0.001)
        #expect(abs(s.sourceRect.midY - 1000) < 0.001)
    }

    /// ★ C-2（レビュー指摘）: `destRect` を一度も主張していなかった。Task 3 は
    /// `ctx.draw(cropped, in: destRect)` にそのまま渡すため、ここが壊れると描画位置が全部狂う。
    /// `destRect` は **View 座標（原点左下・y 上向き）**であり、`sourceRect` と違って y を
    /// 反転してはいけない。
    ///
    /// 手計算: half = 100/2 = 50、srcHalf = 50/2(mag) = 25 → probe = (225,475,50,50)。
    /// drawRect は (0,0,500,1000) で probe を完全に包含するので hit = probe。
    /// dx = (hit.minX-probe.minX)*2 + (cursor.x-half) = 0 + 200 = 200
    /// dy = (hit.minY-probe.minY)*2 + (cursor.y-half) = 0 + 450 = 450
    /// destRect = (200, 450, 100, 100)（ルーペ円に外接する正方形そのもの＝カーソル中心なので当然）
    @Test("destRect は View 座標で返り、ルーペ円の描画先そのものになる")
    func destRectIsInViewCoordinates() throws {
        let r = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)

        let s = try #require(r.first)
        #expect(abs(s.destRect.minX - 200) < 0.001)
        #expect(abs(s.destRect.minY - 450) < 0.001)
        #expect(abs(s.destRect.width - 100) < 0.001)
        #expect(abs(s.destRect.height - 100) < 0.001)
    }

    @Test("倍率を上げると取る矩形が小さくなる")
    func higherMagnificationTakesSmallerRect() throws {
        let a = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)
        let b = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 4)

        let wa = try #require(a.first).sourceRect.width
        let wb = try #require(b.first).sourceRect.width
        #expect(wb < wa, "倍率 4 は倍率 2 より狭い範囲を取る")
        #expect(abs(wb * 2 - wa) < 0.001, "倍率が 2 倍なら取る幅は半分")
    }

    /// ★ ズーム中は実効倍率が `scale × magnification` になる。
    @Test("ズーム中は取る矩形がさらに小さくなる")
    func zoomedInTakesSmallerRect() throws {
        let fit = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)
        let zoomed = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 1.0, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)

        let wf = try #require(fit.first).sourceRect.width
        let wz = try #require(zoomed.first).sourceRect.width
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
    /// ★ I-2（レビュー指摘）: 件数と index だけでなく、2 断片が **相補的**（合わせてルーペの
    /// 正方形全体を過不足なく覆い、重複しない）ことを主張する。
    ///
    /// 手計算: two = [1000x2000, 1000x2000], view=1000x1000, scale=0.5 → drawRect[0]=(500,0,500,1000)
    /// （firstOnRight のため index 0 が右）, drawRect[1]=(0,0,500,1000)。
    /// probe = (475,475,50,50)（cursor 500,500, half=50, srcHalf=25）。
    /// hit0 = (500,475,25,50) → destRect0 = (500,450,50,100)
    /// hit1 = (475,475,25,50) → destRect1 = (450,450,50,100)
    /// destRect0 ∪ destRect1 = (450,450,100,100) = ルーペ正方形そのもの。重複なし（x=500 で接するのみ）。
    @Test("見開きの境界をまたぐと 2 枚から取る")
    func acrossTheGutterTakesFromBothPages() throws {
        let two = [CGSize(width: 1000, height: 2000), CGSize(width: 1000, height: 2000)]
        // 2 枚が横に並ぶので合計 2000x2000。ビュー 1000x1000 なら fitScale 0.5。
        let r = CanvasFitMath.loupeSource(
            images: two, nativeSizes: two, viewSize: CGSize(width: 1000, height: 1000),
            scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 500, y: 500), loupeDiameter: 100, magnification: 2)

        #expect(r.count == 2, "境界の真上なら両ページから断片を取る")
        #expect(Set(r.map(\.imageIndex)) == Set([0, 1]))

        // 相補性: 2 断片の destRect を合わせるとルーペ正方形（100x100）を過不足なく覆う。
        let d0 = try #require(r.first(where: { $0.imageIndex == 0 })).destRect
        let d1 = try #require(r.first(where: { $0.imageIndex == 1 })).destRect
        let union = d0.union(d1)
        #expect(abs(union.width - 100) < 0.001, "2 断片を合わせるとルーペ全幅を覆う")
        #expect(abs(union.height - 100) < 0.001)
        #expect(abs(union.minX - 450) < 0.001)
        #expect(abs(union.minY - 450) < 0.001)

        // 重複なし: 境界で接するだけで、面積のある重なりは無い。
        let overlap = d0.intersection(d1)
        #expect(overlap.isNull || overlap.width < 0.001 || overlap.height < 0.001,
                "2 断片は境界で接するだけで、面積のある重複があってはならない")
    }

    /// ★ 解像度の違うページが混在する巻（実例: 1131x1608 と 1351x1920）。
    /// `images` は高さ正規化済みなので、`sourceRect` は**実ピクセル座標**で返らねばならない。
    /// これを取り違えると `CGImage.cropping(to:)` が誤った領域を切り出す。
    @Test("解像度が混在しても sourceRect は実ピクセル座標で返る")
    func mixedResolutionUsesNativePixels() throws {
        // 実寸 500x1000 の画像を、正規化で 1000x2000 相当に引き伸ばして配置している状況。
        let native = CGSize(width: 500, height: 1000)
        let normalized = CGSize(width: 1000, height: 2000)

        let r = CanvasFitMath.loupeSource(
            images: [normalized], nativeSizes: [native],
            viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)

        let s = try #require(r.first)
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

    /// ★ I-3（レビュー指摘）: `images.count == nativeSizes.count` の guard が未テストだった。
    /// Task 3 は 2 つの配列を別々に渡すため、要素数の食い違いは現実に起こりうる。
    @Test("images と nativeSizes の要素数が食い違うと何も返さない")
    func mismatchedCountsReturnsNothing() {
        let r = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img, img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)
        #expect(r.isEmpty)
    }

    /// ★ I-3: `loupeDiameter > 0` の guard が未テストだった。
    @Test("ルーペ直径が 0 以下なら何も返さない")
    func nonPositiveLoupeDiameterReturnsNothing() {
        let r = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 0, magnification: 2)
        #expect(r.isEmpty)
    }

    /// ★ I-3: `magnification > 0` の guard が未テストだった。
    @Test("倍率が 0 以下なら何も返さない")
    func nonPositiveMagnificationReturnsNothing() {
        let r = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 0)
        #expect(r.isEmpty)
    }

    /// ★ I-3: `scale > 0` の guard が未テストだった。
    @Test("scale が 0 以下なら何も返さない")
    func nonPositiveScaleReturnsNothing() {
        let r = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)
        #expect(r.isEmpty)
    }

    /// パンしていてもカーソル下の内容が正しく取れる。
    @Test("パン中でもカーソル下の内容を取る")
    func panningShiftsTheSourceRect() throws {
        let noPan = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)
        let panned = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: CGSize(width: 50, height: 0),
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 500), loupeDiameter: 100, magnification: 2)

        let a = try #require(noPan.first).sourceRect
        let b = try #require(panned.first).sourceRect
        // 画像が右へ 50 pt 動いた＝同じカーソル位置は画像の左寄りを指す。
        // scale 0.5 なので元画像では 100 px 分。
        #expect(abs((a.midX - b.midX) - 100) < 0.001)
    }

    /// ★ C-1（レビュー指摘）: 全テストのカーソルが縦中央にあり、`sourceRect` の y 反転
    /// （`nativeSizes[i].height - nyFromBottom * ky - ph`）を丸ごと `nyFromBottom * ky` に
    /// 差し替えても 8/8 通っていた（`centerOfImage` は上下対称な条件なので反転を間違えても
    /// 一致する）。カーソルを縦中央からずらし、y 反転そのものを主張する。
    ///
    /// 手計算（cursor y=800, 縦中央 500 より上）:
    /// drawRect=(0,0,500,1000)。probe=(225,775,50,50)（srcHalf=25）。hit=probe（drawRect に包含）。
    /// nx=(225-0)/0.5=450, nyFromBottom=(775-0)/0.5=1550, nw=nh=100。kx=ky=1（native=images）。
    /// py = nativeSizes.height - nyFromBottom*ky - ph = 2000 - 1550 - 100 = 350。
    /// → sourceRect = (450, 350, 100, 100)。
    @Test("縦中央からずれたカーソルで y 反転が効く")
    func offCenterCursorConfirmsYFlip() throws {
        let r = CanvasFitMath.loupeSource(
            images: [img], nativeSizes: [img], viewSize: view, scale: 0.5, offset: .zero,
            gutter: 0, firstOnRight: true,
            cursor: CGPoint(x: 250, y: 800), loupeDiameter: 100, magnification: 2)

        let s = try #require(r.first)
        #expect(abs(s.sourceRect.minX - 450) < 0.001)
        #expect(abs(s.sourceRect.minY - 350) < 0.001)
        #expect(abs(s.sourceRect.width - 100) < 0.001)
        #expect(abs(s.sourceRect.height - 100) < 0.001)
    }
}
