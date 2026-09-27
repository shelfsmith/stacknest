// SPDX-License-Identifier: MIT
import Foundation

/// Sources（SPM）層の文言を引く（G55）。キーは日本語の原文そのもの。
public enum L10n {
    public static func text(_ ja: String, _ lang: L10nLang = .current) -> String {
        text(ja, lang, table: L10nTable.all)
    }

    public static func format(_ ja: String, _ args: any CVarArg..., lang: L10nLang = .current) -> String {
        format(ja, args, lang: lang, table: L10nTable.all)
    }

    public static func plural(_ ja: String, count: Int, _ args: any CVarArg..., lang: L10nLang = .current) -> String {
        plural(ja, count: count, args, lang: lang, table: L10nTable.all)
    }

    // MARK: - Table-injectable (tests)

    static func text(_ ja: String, _ lang: L10nLang, table: [String: L10nEntry]) -> String {
        guard lang == .en, let e = table[ja] else { return ja }
        return e.en
    }

    static func format(_ ja: String, _ args: any CVarArg..., lang: L10nLang, table: [String: L10nEntry]) -> String {
        format(ja, args, lang: lang, table: table)
    }

    static func format(_ ja: String, _ args: [any CVarArg], lang: L10nLang, table: [String: L10nEntry]) -> String {
        // `locale: nil`（POSIX）で固定する。ロケール（ja_JP/en_US）を渡すと桁区切りのカンマが入り
        // （例: id=1234 → "id=1,234"）、書籍 ID 等のコマンドへのコピペが壊れる（G55 回帰）。
        // 単複の選択は `lang` で行うので、書式そのものにロケールは要らない。
        String(format: text(ja, lang, table: table), locale: nil, arguments: args)
    }

    static func plural(_ ja: String, count: Int, _ args: any CVarArg..., lang: L10nLang, table: [String: L10nEntry]) -> String {
        plural(ja, count: count, args, lang: lang, table: table)
    }

    static func plural(_ ja: String, count: Int, _ args: [any CVarArg], lang: L10nLang, table: [String: L10nEntry]) -> String {
        var pattern = ja
        if lang == .en, let e = table[ja] { pattern = e.enPlural.map { count == 1 ? $0.one : $0.other } ?? e.en }
        // `locale: nil`（POSIX）で固定する。理由は `format(_:_:lang:table:)` のコメント参照。
        return String(format: pattern, locale: nil, arguments: args)
    }

    /// 書式指定子の多重集合（ソート済み）。位置指定 `%1$@` は `%@` として数える。`%%` は数えない。
    /// 引数の並び順までは検査できない（`formatSpecifierSequence(in:)` を使うこと）。後方互換のために残す。
    public static func formatSpecifiers(in s: String) -> [String] {
        formatMatches(in: s).map(\.spec).sorted()
    }

    /// 書式指定子を **引数として消費される順** に並べて返す。位置指定 `%N$` があれば N の昇順、
    /// 無ければ出現順（左から右）。位置は取り除いて返す（`%1$@` → `%@`）。`%%` は数えない。
    public static func formatSpecifierSequence(in s: String) -> [String] {
        let matches = formatMatches(in: s)
        guard matches.contains(where: { $0.position != nil }) else {
            return matches.map(\.spec)
        }
        return matches
            .enumerated()
            .sorted { lhs, rhs in
                let lp = lhs.element.position ?? Int.max
                let rp = rhs.element.position ?? Int.max
                if lp != rp { return lp < rp }
                return lhs.offset < rhs.offset
            }
            .map { $0.element.spec }
    }

    private static let formatSpecifierPattern =
        #"%(?:(\d+)\$)?([-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA])|%%"#

    private static func formatMatches(in s: String) -> [(position: Int?, spec: String)] {
        let re = try! NSRegularExpression(pattern: formatSpecifierPattern)
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let whole = ns.substring(with: m.range)
            if whole == "%%" { return nil }
            let spec = "%" + ns.substring(with: m.range(at: 2))
            let posRange = m.range(at: 1)
            let position = posRange.location == NSNotFound ? nil : Int(ns.substring(with: posRange))
            return (position, spec)
        }
    }
}
