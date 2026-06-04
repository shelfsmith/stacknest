// SPDX-License-Identifier: MIT
import Foundation

/// Stackroom 互換のマルチ値仕様ヘルパ。
/// DB は単一文字列 (例: "マンガ, 小説") のまま、UI/filter レイヤーで split してマルチ扱いする。
public enum MultiValueParser {
    public static let separator = ", "

    /// "マンガ, 小説" → ["マンガ", "小説"]。trim + empty filter。
    public static func split(_ raw: String) -> [String] {
        raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// ["マンガ", "小説"] → "マンガ, 小説"
    public static func join(_ values: [String]) -> String {
        values.joined(separator: separator)
    }

    /// (existing, value) → (newJoined, didAdd)
    /// 重複は skip (didAdd = false)
    public static func append(to existing: String?, value: String) -> (String, Bool) {
        let parts = split(existing ?? "")
        if parts.contains(value) {
            return (join(parts), false)
        }
        return (join(parts + [value]), true)
    }

    /// value が存在するか
    public static func contains(_ raw: String, value: String) -> Bool {
        split(raw).contains(value)
    }
}
