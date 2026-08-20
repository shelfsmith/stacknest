// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation

/// ルーペの形。**描画のクリップ形状だけの関心事**で、`CanvasFitMath.loupeSource` には影響しない
/// （あの純関数はもともと正方形の probe を計算しており、円はクリップで作っている）。
public enum LoupeShape: String, Codable, CaseIterable, Sendable {
    case circle
    case square

    public static let defaultValue: LoupeShape = .circle

    public var displayName: String {
        switch self {
        case .circle: return "円"
        case .square: return "正方形"
        }
    }
}

/// ルーペの倍率。範囲・既定値・スクロール量からの変換をここに集約する。
///
/// **上限を「鮮明に保てる範囲」で切っていない。** 実測（G38 smoke）では、ページ 1133×1600 を
/// 高さ 1440px のビューポートに収めるとフィットが 0.9× 等倍で、**2 倍のルーペは既に 1.8× 等倍**。
/// それでもユーザー判定は「使いやすい」だった —— 効いているのは鮮明さではなく**可読性**なので、
/// 等倍を超える領域を落としてはいけない。
public enum LoupeMagnification {
    public static let range: ClosedRange<CGFloat> = 1.5...8.0
    public static let defaultValue: CGFloat = 2.0

    /// 1 ホイールノッチ（生の delta 10 相当）あたりの倍率比。約 12%。
    private static let notchedGain: CGFloat = 0.0115
    /// トラックパッドは連続値が毎フレーム来るので、1 単位あたりを小さくする。
    private static let preciseGain: CGFloat = 0.0030

    /// 範囲外・壊れた値を畳む。NaN / ±∞ は**既定値**へ（範囲端へ倒すと意図しない倍率で固定される）。
    public static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 現在の倍率にスクロール量を適用した新しい倍率。**乗算**で動かす。
    public static func stepped(from current: CGFloat, scrollDeltaY: CGFloat, hasPreciseDeltas: Bool) -> CGFloat {
        guard scrollDeltaY.isFinite, scrollDeltaY != 0 else { return clamp(current) }
        let gain = hasPreciseDeltas ? preciseGain : notchedGain
        return clamp(clamp(current) * exp(scrollDeltaY * gain))
    }
}

public extension LoupeMagnification {
    /// 再デコード判定に使う実効倍率。ルーペ OFF ならズーム倍率そのもの。
    /// **`2.0` を直に書かないための単一の入口。**
    static func effectiveZoomFactor(zoomFactor: CGFloat, loupeEnabled: Bool, magnification: CGFloat) -> CGFloat {
        loupeEnabled ? zoomFactor * clamp(magnification) : zoomFactor
    }
}
