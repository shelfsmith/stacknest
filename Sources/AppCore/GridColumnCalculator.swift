// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics

/// Phase 2.5k: LazyVGrid (.adaptive(minimum: size, maximum: size)) の列数を
/// viewport 幅から派生する純粋関数。grid 矢印 navigation で 1 行下/上を計算する際に
/// 必要となる列数を提供する。最低 1 を保証 (病的 viewport=0 でも 1 列扱い)。
public enum GridColumnCalculator {
    /// `viewportWidth` を `itemMinSize × n + spacing × (n-1)` 形式で詰め込める最大の n を返す。
    /// 式: floor((viewportWidth + spacing) / (itemMinSize + spacing))、ただし最低 1。
    public static func columns(
        viewportWidth: CGFloat,
        itemMinSize: CGFloat,
        spacing: CGFloat
    ) -> Int {
        guard itemMinSize > 0 else { return 1 }
        let denominator = itemMinSize + spacing
        guard denominator > 0 else { return 1 }
        let raw = Int(floor((viewportWidth + spacing) / denominator))
        return max(1, raw)
    }
}
