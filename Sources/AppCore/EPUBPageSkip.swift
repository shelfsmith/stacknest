// SPDX-License-Identifier: MIT
import Foundation

/// G57: 電子書籍の窓の Tab／⇧Tab（「Tab スキップのページ数」だけ本全体のページを進める・戻す）の飛び先。
/// 全体ページ数（Washi の census）があるときだけ使う。計測前は窓が移動しない。
public enum EPUBPageSkip {
    /// 今表示している範囲の開始ページ（0 始まり）から `delta` ページ動かし、`0...pageCount-1` に収める。
    /// 見開きでも基点は開始ページ（画像ビューアの `skipPages` と同じく、先頭・末尾で止める）。
    public static func targetPage(currentStart: Int, by delta: Int, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        return min(pageCount - 1, max(0, currentStart + delta))
    }
}
