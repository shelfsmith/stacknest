// SPDX-License-Identifier: MIT
import LibraryStore
import EPUBAdapter

/// G48-2b: EPUB の綴じ方向（`EPUBReadingDirection`）を書籍レコードの `PageDirection` へ写像する。
/// `.unknown` は「書かない」（nil）— 既存本の既定表示・ユーザー設定を上書きしないため。
public enum EPUBPageDirectionMapping {
    public static func pageDirection(from direction: EPUBReadingDirection) -> PageDirection? {
        switch direction {
        case .rtl: return .rightToLeft
        case .ltr: return .leftToRight
        case .unknown: return nil
        }
    }
}
