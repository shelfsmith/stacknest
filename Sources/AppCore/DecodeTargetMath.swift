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
}
