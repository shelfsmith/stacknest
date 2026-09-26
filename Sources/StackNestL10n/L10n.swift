// SPDX-License-Identifier: MIT
import Foundation

/// Sources（SPM）層の文言を引く（G55）。キーは日本語の原文そのもの。
public enum L10n {
    public static func text(_ ja: String, _ lang: L10nLang = .current) -> String {
        text(ja, lang, table: L10nTable.all)
    }

    public static func format(_ ja: String, _ lang: L10nLang = .current, _ args: any CVarArg...) -> String {
        format(ja, lang, table: L10nTable.all, args)
    }

    public static func plural(_ ja: String, count: Int, _ lang: L10nLang = .current, _ args: any CVarArg...) -> String {
        plural(ja, count: count, lang, table: L10nTable.all, args)
    }

    // MARK: - Table-injectable (tests)

    static func text(_ ja: String, _ lang: L10nLang, table: [String: L10nEntry]) -> String {
        guard lang == .en, let e = table[ja] else { return ja }
        return e.en
    }

    static func format(_ ja: String, _ lang: L10nLang, table: [String: L10nEntry], _ args: any CVarArg...) -> String {
        format(ja, lang, table: table, args)
    }

    static func format(_ ja: String, _ lang: L10nLang, table: [String: L10nEntry], _ args: [any CVarArg]) -> String {
        String(format: text(ja, lang, table: table), locale: locale(lang), arguments: args)
    }

    static func plural(_ ja: String, count: Int, _ lang: L10nLang, table: [String: L10nEntry], _ args: any CVarArg...) -> String {
        plural(ja, count: count, lang, table: table, args)
    }

    static func plural(_ ja: String, count: Int, _ lang: L10nLang, table: [String: L10nEntry], _ args: [any CVarArg]) -> String {
        var pattern = ja
        if lang == .en, let e = table[ja] { pattern = e.enPlural.map { count == 1 ? $0.one : $0.other } ?? e.en }
        return String(format: pattern, locale: locale(lang), arguments: args)
    }

    private static func locale(_ lang: L10nLang) -> Locale { Locale(identifier: lang == .ja ? "ja_JP" : "en_US") }

    /// 書式指定子の多重集合（ソート済み）。位置指定 `%1$@` は `%@` として数える。`%%` は数えない。
    public static func formatSpecifiers(in s: String) -> [String] {
        let pattern = #"%(?:\d+\$)?([-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA])|%%"#
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let whole = ns.substring(with: m.range)
            if whole == "%%" { return nil }
            return "%" + ns.substring(with: m.range(at: 1))
        }.sorted()
    }
}
