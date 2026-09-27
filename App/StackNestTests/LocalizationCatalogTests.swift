// SPDX-License-Identifier: MIT
import Testing
import Foundation
import StackNestL10n
@testable import StackNest

/// G55: 出荷するカタログの全キーに英訳があり、書式指定子が食い違わない（Review Focus 3）。
@Suite("String Catalog の網羅（G55）")
struct LocalizationCatalogTests {
    private func catalog(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StackNest/\(name)")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return obj["strings"] as! [String: Any]
    }

    @Test("Localizable.xcstrings の全キーに en がある", arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings"])
    func everyKeyHasEnglish(file: String) throws {
        guard let strings = try? catalog(file) else { return }   // InfoPlist が無い構成を許す
        var missing: [String] = []
        for (key, v) in strings {
            let en = ((v as? [String: Any])?["localizations"] as? [String: Any])?["en"]
            if en == nil { missing.append(key) }
        }
        #expect(missing.isEmpty, "\(missing.sorted().prefix(20))")
    }

    /// 引数の並び順まで見る（`formatSpecifiers` はソート済みの多重集合なので、`%@ → Finder: %lld`
    /// のような並び替え・位置指定 (`%1$@` 等) の食い違いを見逃す。`formatSpecifierSequence` を使う）。
    @Test("キーと en の書式指定子が並び順まで一致する")
    func specifiersMatch() throws {
        for (key, v) in try catalog("Localizable.xcstrings") {
            guard let en = ((v as? [String: Any])?["localizations"] as? [String: Any])?["en"] as? [String: Any] else { continue }
            var values: [String] = []
            if let unit = en["stringUnit"] as? [String: Any], let s = unit["value"] as? String { values.append(s) }
            if let plural = (en["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                for case let form as [String: Any] in plural.values {
                    if let s = (form["stringUnit"] as? [String: Any])?["value"] as? String { values.append(s) }
                }
            }
            for s in values {
                #expect(L10n.formatSpecifierSequence(in: s) == L10n.formatSpecifierSequence(in: key), "\(key) → \(s)")
            }
        }
    }

    // MARK: - 実際に英語で引けるか（Task 17 補足）

    private func lproj(_ lang: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: lang, ofType: "lproj"), "\(lang).lproj がアプリに無い")
        return try #require(Bundle(path: path))
    }

    /// `String(localized:)` と同じ引き方（表に無ければ渡した既定値が返る）。単純な文字列専用
    /// （単複つきは `%#@value@` という素の書式指定子しか返らないため、`stringsdictPluralOther`
    /// で `.stringsdict` を直接読む）。
    private func lookup(_ bundle: Bundle, _ key: String, default value: String) -> String {
        bundle.localizedString(forKey: key, value: value, table: "Localizable")
    }

    /// 単複つきの英訳（"other" フォーム）を `Localizable.stringsdict` から直接読む。
    /// `bundle.localizedString(forKey:value:table:)` はプレースホルダ（`%#@value@`）しか返さず、
    /// 実際の単複展開は現在のプロセスのロケールに依存するため、`-testLanguage ja` のままでも
    /// 確実に en 側を検査できるよう、コンパイル済みの `.stringsdict` の中身を直接検査する。
    private func stringsdictPluralOther(_ bundle: Bundle, _ key: String) throws -> String {
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "stringsdict"),
                                "Localizable.stringsdict が en.lproj に無い")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try #require(plist as? [String: Any])
        let entry = try #require(dict[key] as? [String: Any], "\(key) が stringsdict に無い")
        let value = try #require(entry["value"] as? [String: Any])
        return try #require(value["other"] as? String)
    }

    /// 代表的なキーが `en.lproj` から実際に英語で引けることを確かめる（`-testLanguage ja` のままでも
    /// 通る形＝プロセス言語ではなく `en.lproj` のバンドルを直接開いて検査する）。
    @Test("代表的なキーが en.lproj から英語で引ける")
    func englishBundleResolvesRepresentativeKeys() throws {
        let en = try lproj("en")
        // 単純な文字列。
        #expect(lookup(en, "削除", default: "削除") == "Delete")
        // 単複つき（"other" フォームがカタログどおり展開されて en.lproj に入っていることの確認）。
        #expect(try stringsdictPluralOther(en, "%lld 件") == "%lld items")
        // U1 のシェルフ／お気に入り系のアラート。
        #expect(lookup(en, "お気に入りシェルフが見つかりません", default: "お気に入りシェルフが見つかりません")
                == "The Favorites shelf can't be found.")
    }
}
