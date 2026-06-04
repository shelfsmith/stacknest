// SPDX-License-Identifier: MIT
import Foundation

/// ページ単位の手動レイアウトオーバーライド。行が無い（nil）= 自動判定。
/// rawValue は LibraryStore の `book_page_layout.mode` 列に整数で永続化される
/// （0 = forcePair, 1 = forceSolo）。LibraryStore は AppCore に依存しないため、
/// 値の往復は App 層が `PageLayoutOverride(rawValue:)` で行う。
public enum PageLayoutOverride: Int, Codable, Sendable, Equatable {
    case forcePair = 0   // 横長でも強制的にペア対象
    case forceSolo = 1   // 縦長でも強制的に単独
}

/// 1 見開き。`pages` は **読む順**（pages[0] を先に読む）。1 要素=単独、2 要素=見開き。
/// 左右どちらに pages[0] を置くかは描画側（canvas の firstOnRight）が決める。
public struct Spread: Sendable, Equatable {
    public let pages: [Int]          // 0-based ページ索引
    public init(pages: [Int]) { self.pages = pages }
    public var isSolo: Bool { pages.count == 1 }
}

/// 見開き配列を生成する純関数。読む方向には非依存。
public enum SpreadPaginator {
    /// `pageCount` ページを 0..<pageCount まで漏れなく覆う見開き配列を返す。
    /// - isLandscape: そのページが横長か（寸法未取得時は呼び出し側が false=縦長を返す）
    /// - override:    そのページの手動オーバーライド（nil = 自動）
    /// - coverOffset: true なら先頭ページを単独表示してからペアを組む
    public static func paginate(
        pageCount: Int,
        isLandscape: (Int) -> Bool,
        override: (Int) -> PageLayoutOverride?,
        coverOffset: Bool
    ) -> [Spread] {
        guard pageCount > 0 else { return [] }

        func effectiveSolo(_ p: Int) -> Bool {
            if let ov = override(p) { return ov == .forceSolo }
            return isLandscape(p)
        }

        var spreads: [Spread] = []
        var i = 0
        if coverOffset && override(0) != .forcePair {
            spreads.append(Spread(pages: [0]))
            i = 1
        }
        while i < pageCount {
            if effectiveSolo(i) {
                spreads.append(Spread(pages: [i]))
                i += 1
            } else if i + 1 < pageCount && !effectiveSolo(i + 1) {
                spreads.append(Spread(pages: [i, i + 1]))
                i += 2
            } else {
                spreads.append(Spread(pages: [i]))
                i += 1
            }
        }
        return spreads
    }
}
