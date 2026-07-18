// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics

/// G18 C3: 内蔵ビューアのデコード先ピクセルサイズ（`maxPixelSize`）を、canvas の実表示
/// ピクセル（backing pixel）から精密に算出する純粋計算。UI 非依存（CoreGraphics の値型のみ）。
///
/// C2 では canvas の bounds（バッキングスケール込み）から大まかな上限を出す暫定実装だった
/// （見開き時も canvas 全幅を基準にしてしまい、片ページを過剰にデコードしていた）。
/// C3 はこれを次の通り精密化する:
/// - 見開き表示中は 1 ページが canvas 幅のおよそ半分しか占めないため、片ページの目標は
///   半幅を基準に算出する（過剰デコード防止）。
/// - 若干のズーム/拡大表示でも鮮明に見えるよう、実表示ピクセルに headroom 倍率を掛ける。
/// - 極端に大きいウィンドウ/5K ディスプレイでも青天井にしない上限（ceiling）、
///   極小ウィンドウでも荒れすぎないよう最低限を確保する下限（floor）でクランプする。
public enum DecodeTargetMath {
    /// 実表示ピクセルに掛ける余裕率（軽いズーム/アップスケール表示でも鮮明さを保つ）。
    public static let headroomMultiplier: CGFloat = 1.25
    /// デコード先の上限（px）。
    public static let ceilingPixelSize = 6000
    /// デコード先の下限（px）。極小ウィンドウでも過度に荒れないよう最低限を確保する。
    public static let floorPixelSize = 1600
    /// canvas サイズ/backingScaleFactor が未確定（レイアウト前・ウィンドウ未取得等）なときの
    /// フォールバック値。
    public static let fallbackPixelSize = 4000

    /// canvas の実表示ピクセルサイズから、デコード先の目標最大辺（px）を算出する。
    ///
    /// - Parameters:
    ///   - canvasSize: canvas の bounds サイズ（ポイント単位、`NSView.bounds.size` 相当）。
    ///   - backingScaleFactor: `window.backingScaleFactor`（Retina なら 2.0 等）。
    ///   - isSpread: 見開き表示中か。true の場合、1 ページが占めるのは canvas 幅のおよそ半分
    ///     なので、片ページの目標は半幅を基準に算出する。false（単ページ）は全幅を基準にする。
    /// - Returns: `ViewerImageDecoder.decode(_:maxPixelSize:)` にそのまま渡せる最大辺（px）。
    ///   `canvasSize`/`backingScaleFactor` が不正（0・非有限）なら `fallbackPixelSize` を返す。
    public static func decodeTargetMaxPixelSize(
        canvasSize: CGSize,
        backingScaleFactor: CGFloat,
        isSpread: Bool
    ) -> Int {
        guard canvasSize.width.isFinite, canvasSize.width > 0,
              canvasSize.height.isFinite, canvasSize.height > 0,
              backingScaleFactor.isFinite, backingScaleFactor > 0 else {
            return fallbackPixelSize
        }
        let perPageWidth = isSpread ? canvasSize.width / 2 : canvasSize.width
        let longestEdgePoints = max(perPageWidth, canvasSize.height)
        let backingPixels = longestEdgePoints * backingScaleFactor
        let withHeadroom = backingPixels * headroomMultiplier
        let clamped = min(max(withHeadroom, CGFloat(floorPixelSize)), CGFloat(ceilingPixelSize))
        return Int(clamped.rounded())
    }

    // MARK: - G18 C4: ズーム時の再デコード（画質維持）

    /// zoom=1（フィット）基準の `baseTarget`（`decodeTargetMaxPixelSize` の結果）に、現在の
    /// canvas zoom 倍率を乗算し、ズーム後の表示に必要なデコード先ピクセルサイズを算出する。
    ///
    /// `scale = fitScale * zoomFactor` で描画するため、fit 時（zoomFactor=1）を基準に算出した
    /// `baseTarget` に対して表示ピクセルは zoomFactor に比例して増える。ImageIO の thumbnail API
    /// （`kCGImageSourceThumbnailMaxPixelSize`）は upscale しない（ネイティブ解像度を超えて
    /// 要求しても実際の出力はネイティブ解像度に留まる）ため、ここでの「ネイティブ解像度との
    /// min」は呼び出し側で明示的に取る必要はなく、`ceilingPixelSize` でクランプした値を
    /// そのまま `maxPixelSize` として渡せば ImageIO 側が自然に `min(native, target)` を実現する。
    /// - Parameters:
    ///   - baseTarget: `decodeTargetMaxPixelSize(...)` の結果（zoomFactor 未反映）。
    ///   - zoomFactor: canvas の現在の zoom 倍率（1.0 = フィット、それ以上が拡大）。
    /// - Returns: `ceilingPixelSize` でクランプしたズーム込みの target。`baseTarget` が 0 以下、
    ///   または `zoomFactor` が不正（非有限・0 以下）なら `baseTarget` をそのまま返す。
    public static func zoomDecodeTarget(baseTarget: Int, zoomFactor: CGFloat) -> Int {
        guard baseTarget > 0, zoomFactor.isFinite, zoomFactor > 0 else { return baseTarget }
        let scaled = CGFloat(baseTarget) * zoomFactor
        let clamped = min(scaled, CGFloat(ceilingPixelSize))
        return Int(clamped.rounded())
    }

    /// 直近に要求した target（`lastTarget`）に対し、ズーム後の target（`newTarget`）が
    /// `growthThreshold` を超えて大きくなったかを判定する。僅かな拡大では再デコードしない
    /// （resize 再デコード同様の「成長率で判定」方式。境界での churn を避ける）。
    /// `lastTarget`/`newTarget` が 0 以下なら常に false（判定不能・未デコード状態）。
    public static func shouldRedecodeForZoom(lastTarget: Int, newTarget: Int, growthThreshold: CGFloat) -> Bool {
        guard lastTarget > 0, newTarget > 0 else { return false }
        return CGFloat(newTarget) > CGFloat(lastTarget) * growthThreshold
    }
}
