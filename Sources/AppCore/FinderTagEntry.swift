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

    /// 同期してよい名前か —— **`MultiValueParser` の往復で元に戻るか**で決める（spec §4.4）。
    ///
    /// 当初は「区切り文字 `", "` を含むか」で判定していたが、**それでは足りなかった。**
    /// `MultiValueParser.split` は **`","` で切って前後の空白を trim** するので、
    /// `"SF,ファンタジー"`（空白なし）や `"SF "`（末尾空白）はその判定を素通りし、
    /// **1 個の Finder タグが StackNest 側で 2 個の値になる**（レビューで実測）。
    /// しかも `skippedTags` に載らないのでユーザーは気づけず、
    /// 毎回「更新した」と報告され続ける（冪等性も壊れる）。
    ///
    /// 判定を往復そのものに置き換えれば、区切りの仕様が変わっても自動的に追随する。
    public static func isSyncable(_ name: String) -> Bool {
        !name.isEmpty && MultiValueParser.split(name) == [name]
    }
}
