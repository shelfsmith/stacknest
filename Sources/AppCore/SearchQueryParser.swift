// SPDX-License-Identifier: MIT
import Foundation

/// 検索欄クエリの解釈ヘルパ（純ロジック）。
public enum SearchQueryParser {
    /// `#<整数>` 形式（前後空白・# の直後空白許容）なら book ID を返す。非該当は nil。
    /// 例: "#123" -> 123, "  #  12 " -> 12, "abc"/"#"/"#12a"/"123" -> nil。
    public static func bookID(from query: String) -> Int? {
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("#") else { return nil }
        let rest = t.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, rest.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(rest)
    }
}
