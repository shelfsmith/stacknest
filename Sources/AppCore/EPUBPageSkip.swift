// SPDX-License-Identifier: MIT
import Foundation

/// G57: 電子書籍の窓の Tab／⇧Tab（「Tab スキップのページ数」だけ本全体のページを進める・戻す）の飛び先。
/// 全体ページ数（Washi の census）があるときだけ使う。計測前は窓が移動しない。
public enum EPUBPageSkip {
    /// 今表示している範囲（0 始まり、見開きなら 2 ページ）から `delta` ページ動かし、`0...pageCount-1` に収める。
    /// 基点は開始ページ。ただし必ず今の範囲の外へ出す（前へは末尾の次以降、後ろへは開始の前以前）。
    /// Washi は見開きの開始ページへ丸めるため、見開きで 1 ページだけ進めると右側のページを指して
    /// 同じ見開きに戻り、いつまでも進まない（Codex G57 P2）。
    public static func targetPage(currentRange: ClosedRange<Int>, by delta: Int, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        let raw: Int
        if delta > 0 {
            raw = max(currentRange.lowerBound + delta, currentRange.upperBound + 1)
        } else if delta < 0 {
            raw = min(currentRange.lowerBound + delta, currentRange.lowerBound - 1)
        } else {
            raw = currentRange.lowerBound
        }
        return min(pageCount - 1, max(0, raw))
    }
}
