// SPDX-License-Identifier: MIT
import Foundation

/// G57: 欧文の書体の 1 つの字体（太さ・斜体ごと）。`@font-face` の `local()` に PostScript 名を使う。
public struct EPUBFontFace: Equatable, Sendable {
    public let postScriptName: String
    /// CSS の太さ（100–900）。
    public let weight: Int
    public let italic: Bool

    public init(postScriptName: String, weight: Int, italic: Bool) {
        self.postScriptName = postScriptName
        self.weight = weight
        self.italic = italic
    }
}

/// G57: 見た目の値から、注入する CSS の文字列を組み立てる（純粋関数）。
public enum EPUBAppearanceCSS {
    /// 欧文の書体をラテン文字の範囲に限るための別名。
    static let latinAlias = "StackNest Latin"
    /// 欧文の書体を効かせる範囲（Basic Latin〜Latin Extended-B と Latin Extended Additional）。
    /// 約物（U+2000 台）・かな・漢字は範囲外なので、和文の書体（無ければ serif）へ落ちる。
    static let latinUnicodeRange = "U+0000-024F, U+1E00-1EFF"

    private static let fontFamilySelector = "body, body *:not(code):not(pre):not(kbd):not(samp)"
    private static let forcedColorSelector = "body, body *:not(a):not(a *):not(pre):not(code):not(pre *):not(code *)"

    /// 書体・強制色の CSS 規則をまとめる。規則が 1 つも無ければ nil。複数は改行で連結
    /// （`@font-face`→書体→色の順）。
    /// - Parameter latinFaces: 欧文の書体の字体。空でなければ、欧文の書体を `@font-face` の別名にして
    ///   ラテン文字の範囲だけに効かせる。空なら書体名をそのまま並べる（従来どおり）。
    public static func make(_ a: EPUBAppearanceValue, systemIsDark: Bool,
                            latinFaces: [EPUBFontFace] = []) -> String? {
        var rules: [String] = []
        let hasLatin = !(a.latinFontFamily ?? "").isEmpty
        let useAlias = hasLatin && !latinFaces.isEmpty
        if useAlias {
            rules.append(contentsOf: latinFaces.map(fontFaceRule))
        }
        if let fontRule = fontFamilyRule(a, latinAlias: useAlias) {
            rules.append(fontRule)
        }
        if let color = a.forcedTextColor(systemIsDark: systemIsDark) {
            rules.append("\(forcedColorSelector) { color: \(color.hexString) !important; }")
        }
        return rules.isEmpty ? nil : rules.joined(separator: "\n")
    }

    private static func fontFaceRule(_ f: EPUBFontFace) -> String {
        "@font-face { font-family: \"\(latinAlias)\"; src: local(\"\(escapedFamily(f.postScriptName))\"); "
            + "font-weight: \(f.weight); font-style: \(f.italic ? "italic" : "normal"); "
            + "unicode-range: \(latinUnicodeRange); }"
    }

    private static func fontFamilyRule(_ a: EPUBAppearanceValue, latinAlias useAlias: Bool) -> String? {
        var names: [String] = []
        if let latin = a.latinFontFamily, !latin.isEmpty { names.append(useAlias ? latinAlias : latin) }
        if let japanese = a.japaneseFontFamily, !japanese.isEmpty { names.append(japanese) }
        guard !names.isEmpty else { return nil }
        let quoted = (names.map { "\"\(escapedFamily($0))\"" } + ["serif"]).joined(separator: ", ")
        return "\(fontFamilySelector) { font-family: \(quoted) !important; }"
    }

    /// 制御文字と U+2028／U+2029 を除き、`\` → `\\`、`"` → `\"`。
    static func escapedFamily(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0x2028 || scalar.value == 0x2029 {
                continue
            }
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
