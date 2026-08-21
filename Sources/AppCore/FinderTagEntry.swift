// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

/// Finder タグ 1 件。
///
/// `com.apple.metadata:_kMDItemUserTags` は binary plist の文字列配列で、各要素は
/// **色付きなら `"名前\n色番号"`、色無しなら `"名前"`**（spec §4.3・実測）。
/// 素朴に名前だけ扱うと、書き戻しで**ユーザーのタグ色が消える**。色番号をここで保持する。
public struct FinderTagEntry: Equatable, Sendable {
    public let name: String
    /// Finder の色番号（0〜7）。色無しは nil。**StackNest 側では編集しないが、捨てない。**
    public let colorIndex: Int?

    public init(name: String, colorIndex: Int?) {
        self.name = name
        self.colorIndex = colorIndex
    }

    public static func parse(_ raw: String) -> FinderTagEntry {
        // 最初の改行で切る。名前に改行が入った異常データでも、色番号として読めなければ色無し。
        guard let nl = raw.firstIndex(of: "\n") else {
            return FinderTagEntry(name: raw, colorIndex: nil)
        }
        let name = String(raw[raw.startIndex..<nl])
        let rest = String(raw[raw.index(after: nl)...])
        return FinderTagEntry(name: name, colorIndex: Int(rest))
    }

    public var rawValue: String {
        guard let colorIndex else { return name }
        return "\(name)\n\(colorIndex)"
    }

    /// 同期してよい名前か。`MultiValueParser` の区切り（`", "`）を含むタグは、往復で
    /// 2 つに分裂して**元に戻らない**ので同期しない（spec §4.4）。空も除く。
    public static func isSyncable(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(MultiValueParser.separator)
    }
}
