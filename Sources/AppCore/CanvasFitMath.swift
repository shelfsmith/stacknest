// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics

/// 内蔵ビューワ canvas のフィット倍率・ズームクランプ・パンオフセットクランプの純粋計算。
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
}
