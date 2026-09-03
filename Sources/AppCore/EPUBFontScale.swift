// SPDX-License-Identifier: MIT
import Foundation

/// EPUB 内蔵リーダーのフォント倍率。範囲・既定値をここに集約する
/// （`LoupeMagnification` と同じ作法）。範囲は Washi 側の許容範囲
/// （`EPUBReaderView.fontScaleRange`）と一致させている — この層は Washi を
/// import しないので値をリテラルで持つ。
public enum EPUBFontScale {
    public static let range: ClosedRange<Double> = 0.5...3.0
    public static let defaultValue: Double = 1.0

    /// 範囲外・壊れた値を畳む。NaN / ±∞ は**既定値**へ（範囲端へ倒すと意図しない倍率で固定される）。
    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
