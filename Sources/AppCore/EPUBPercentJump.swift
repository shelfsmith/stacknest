// SPDX-License-Identifier: MIT
import Foundation

/// G51: 数字キー（0〜9）の割合ジャンプを EPUB でどこへ飛ばすか。**本全体**に対する割合（章内ではない）。
/// 画像ビューアの `jumpToPercent` と同じ丸め（`(count - 1) * fraction` を四捨五入）。
public enum EPUBPercentJump {
    /// 全体ページ数（Washi の census）があるとき: 0 始まりの全体ページ番号。
    public static func globalPage(fraction: Double, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        let f = min(1, max(0, fraction))
        return Int((Double(pageCount - 1) * f).rounded())
    }

    /// census が未完了のときの代替: spine 番号（0 始まり）。その項目の先頭へ飛ぶ。
    public static func spineIndex(fraction: Double, spineCount: Int) -> Int? {
        guard spineCount > 0 else { return nil }
        let f = min(1, max(0, fraction))
        return Int((Double(spineCount - 1) * f).rounded())
    }
}
