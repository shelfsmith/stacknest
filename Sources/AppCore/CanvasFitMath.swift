// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics

/// 内蔵ビューア canvas のフィット倍率・ズームクランプ・パンオフセットクランプの純粋計算。
/// UI 非依存（CoreGraphics の値型のみ）。ユニットテスト全網羅。
public enum CanvasFitMath {
    /// 画像をビューに収める倍率（アスペクト維持・拡大も許容）。不正サイズは 1。
    public static func fitScale(imageSize: CGSize, viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    }

    /// scale を [fitScale, fitScale * maxZoomFactor] にクランプ（fit 未満に縮小させない）。
    public static func clampScale(_ scale: CGFloat, fitScale: CGFloat, maxZoomFactor: CGFloat) -> CGFloat {
        guard fitScale > 0 else { return scale }
        return min(max(scale, fitScale), fitScale * maxZoomFactor)
    }

    /// 拡大画像が可視領域から外れすぎないようパンオフセットを ±(余白/2) にクランプ。
    /// 画像がビュー以下（フィット時）は 0（パン不可）。
    public static func clampOffset(_ offset: CGSize, scaledImageSize: CGSize, viewSize: CGSize) -> CGSize {
        let maxX = max(0, (scaledImageSize.width - viewSize.width) / 2)
        let maxY = max(0, (scaledImageSize.height - viewSize.height) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    /// 画像を `scale` 倍・中央基準に `offset` ずらして描画する矩形（ビュー座標）。
    /// 自前描画キャンバスがそのまま `draw(_:)` に渡せる。不正な画像サイズは `.zero`。
    public static func imageDrawRect(imageSize: CGSize, viewSize: CGSize, scale: CGFloat, offset: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scaled = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let originX = (viewSize.width - scaled.width) / 2 + offset.width
        let originY = (viewSize.height - scaled.height) / 2 + offset.height
        return CGRect(x: originX, y: originY, width: scaled.width, height: scaled.height)
    }

    /// 見開き配置前に、各画像を「共通の高さ」へ揃えた論理サイズに正規化する（アスペクト比は各画像で保存）。
    /// 見開きの facing ページは同じ表示高さで並ぶべきなのに、`spreadFitScale`/`spreadDrawRects` は
    /// 単一 scale をネイティブ px サイズに乗算するため、同一アスペクト比でも解像度が異なると
    /// 低解像度側が小さく描画される（実写: 同一巻に 1131x1608 と 1351x1920 が混在する漫画で発生）。
    /// この関数で全ページを最大高さに正規化してから spread 計算へ渡すと、両ページが同じ表示高さになる。
    /// native 画像は正規化後サイズと同一アスペクトの矩形へ描画されるため歪まない。空配列・不正サイズは素通し。
    public static func heightNormalized(_ images: [CGSize]) -> [CGSize] {
        let maxH = images.reduce(0) { max($0, $1.height) }
        guard maxH > 0 else { return images }
        return images.map { img in
            guard img.width > 0, img.height > 0 else { return img }
            let s = maxH / img.height
            return CGSize(width: img.width * s, height: maxH)
        }
    }

    /// 1〜2 枚を横並び（中央ガター）に配置するときの共通フィット倍率。
    /// 横方向: 全幅 + ガター ≤ viewW、縦方向: 最大高 ≤ viewH を同時に満たす最大の s。
    /// n=1 では fitScale と一致する。空配列・不正サイズは 1。
    public static func spreadFitScale(images: [CGSize], viewSize: CGSize, gutter: CGFloat) -> CGFloat {
        guard !images.isEmpty, viewSize.width > 0, viewSize.height > 0 else { return 1 }
        let n = images.count
        let totalWidth = images.reduce(0) { $0 + $1.width }
        let maxHeight = images.reduce(0) { max($0, $1.height) }
        guard totalWidth > 0, maxHeight > 0 else { return 1 }
        let availableWidth = viewSize.width - gutter * CGFloat(n - 1)
        guard availableWidth > 0 else { return 1 }
        let scaleW = availableWidth / totalWidth
        let scaleH = viewSize.height / maxHeight
        return min(scaleW, scaleH)
    }

    /// 横並び見開きの各画像の描画矩形（画像 index 順に 1 つずつ）。
    /// 左→右の並び順は firstOnRight ? indices 逆順 : 自然順。
    /// 各矩形は縦中央揃え。offset は見開き全体に一様適用。空配列は []。
    public static func spreadDrawRects(
        images: [CGSize],
        viewSize: CGSize,
        scale: CGFloat,
        offset: CGSize,
        gutter: CGFloat,
        firstOnRight: Bool
    ) -> [CGRect] {
        guard !images.isEmpty else { return [] }
        let n = images.count
        // 左→右に並べる画像 index の順序
        let order: [Int] = firstOnRight ? Array((0..<n).reversed()) : Array(0..<n)
        let totalW = images.reduce(0) { $0 + $1.width * scale } + gutter * CGFloat(n - 1)
        var x = (viewSize.width - totalW) / 2 + offset.width
        var rects = [CGRect](repeating: .zero, count: n)
        for idx in order {
            let w = images[idx].width * scale
            let h = images[idx].height * scale
            let y = (viewSize.height - h) / 2 + offset.height
            rects[idx] = CGRect(x: x, y: y, width: w, height: h)
            x += w + gutter
        }
        return rects
    }

    // MARK: - ルーペ（G38）

    /// ルーペが 1 枚の画像から取る領域と、その描画先。
    public struct LoupeSource: Equatable, Sendable {
        /// `images` 配列のどれから取るか。
        public let imageIndex: Int
        /// その画像の**ピクセル座標**での矩形（原点左上・y 下向き）。
        public let sourceRect: CGRect
        /// **View 座標**での描画先（原点左下・y 上向き）。
        public let destRect: CGRect
        public init(imageIndex: Int, sourceRect: CGRect, destRect: CGRect) {
            self.imageIndex = imageIndex
            self.sourceRect = sourceRect
            self.destRect = destRect
        }
    }

    /// カーソル位置の周辺を `magnification` 倍で見るとき、各画像から取る領域を求める。
    ///
    /// 見開きのガターをまたぐと**2 枚から断片を取る**ため戻り値は配列。
    /// カーソルが画像の外にあれば空を返す。
    ///
    /// - Parameters:
    ///   - cursor: View 座標のカーソル位置（原点左下・y 上向き）
    ///   - images: **高さ正規化済み**のサイズ（`CanvasFitMath.heightNormalized` の結果）。配置計算に使う
    ///   - nativeSizes: 各画像の**実ピクセル寸法**（`DecodedImage.pixelSize`）。`sourceRect` はこの座標で返る
    ///   - loupeDiameter: ルーペの直径（View pt）
    ///   - magnification: 拡大率。実効倍率は `scale * magnification` になる
    ///
    /// **★ 正規化座標と実ピクセル座標を混同しないこと。** `images` は各ページを同じ高さに
    /// 揃えた値で、解像度の違うページが混在する巻（例: 1131x1608 と 1351x1920）では
    /// 実ピクセル寸法と一致しない。`CGImage.cropping(to:)` は**実ピクセル座標**を要求するので、
    /// `sourceRect` はここで `nativeSizes` へ換算して返す。
    public static func loupeSource(
        images: [CGSize],
        nativeSizes: [CGSize],
        viewSize: CGSize,
        scale: CGFloat,
        offset: CGSize,
        gutter: CGFloat,
        firstOnRight: Bool,
        cursor: CGPoint,
        loupeDiameter: CGFloat,
        magnification: CGFloat
    ) -> [LoupeSource] {
        guard !images.isEmpty, images.count == nativeSizes.count,
              loupeDiameter > 0, magnification > 0, scale > 0 else { return [] }

        let rects = spreadDrawRects(images: images, viewSize: viewSize, scale: scale,
                                    offset: offset, gutter: gutter, firstOnRight: firstOnRight)

        // ルーペが View 上で覆う正方形（円に外接する）。
        let half = loupeDiameter / 2
        // 拡大して見るので、元の View 上では直径 / magnification の範囲を取る。
        let srcHalf = half / magnification
        let probe = CGRect(x: cursor.x - srcHalf, y: cursor.y - srcHalf,
                           width: srcHalf * 2, height: srcHalf * 2)

        var out: [LoupeSource] = []
        for (i, drawRect) in rects.enumerated() where i < images.count {
            let hit = probe.intersection(drawRect)
            guard !hit.isNull, hit.width > 0, hit.height > 0 else { continue }

            // View 座標 → **正規化座標** → **実ピクセル座標**の 2 段変換。
            // 1 段目: drawRect 内の相対位置を scale で割って正規化座標へ
            let nx = (hit.minX - drawRect.minX) / scale
            let nyFromBottom = (hit.minY - drawRect.minY) / scale
            let nw = hit.width / scale
            let nh = hit.height / scale
            // 2 段目: 正規化 → 実ピクセル。images[i] は高さ正規化済みなので比率で換算する。
            let kx = nativeSizes[i].width / max(images[i].width, 0.0001)
            let ky = nativeSizes[i].height / max(images[i].height, 0.0001)
            let px = nx * kx
            let pw = nw * kx
            let ph = nh * ky
            // y は **画像側が原点左上・y 下向き**なので反転する（実ピクセル高さを使う）
            let py = nativeSizes[i].height - nyFromBottom * ky - ph

            let sourceRect = CGRect(x: px, y: py, width: pw, height: ph)

            // 描画先: ルーペ円の中で、probe 内の相対位置を magnification 倍に拡大した位置。
            let dx = (hit.minX - probe.minX) * magnification + (cursor.x - half)
            let dy = (hit.minY - probe.minY) * magnification + (cursor.y - half)
            let destRect = CGRect(x: dx, y: dy,
                                  width: hit.width * magnification,
                                  height: hit.height * magnification)

            out.append(LoupeSource(imageIndex: i, sourceRect: sourceRect, destRect: destRect))
        }
        return out
    }
}
