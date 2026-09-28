// SPDX-License-Identifier: MIT
import Foundation

/// G57: 見た目の値から、注入する CSS の文字列を組み立てる（純粋関数）。
public enum EPUBAppearanceCSS {
    private static let fontFamilySelector = "body, body *:not(code):not(pre):not(kbd):not(samp)"
    private static let forcedColorSelector = "body, body *:not(a):not(a *):not(pre):not(code):not(pre *):not(code *)"

    /// 書体・強制色の CSS 規則をまとめる。規則が 1 つも無ければ nil。複数は改行で連結（書体→色の順）。
    public static func make(_ a: EPUBAppearanceValue, systemIsDark: Bool) -> String? {
        var rules: [String] = []
        if let fontRule = fontFamilyRule(a) {
            rules.append(fontRule)
        }
        if let color = a.forcedTextColor(systemIsDark: systemIsDark) {
            rules.append("\(forcedColorSelector) { color: \(color.hexString) !important; }")
        }
        return rules.isEmpty ? nil : rules.joined(separator: "\n")
    }

    private static func fontFamilyRule(_ a: EPUBAppearanceValue) -> String? {
        var names: [String] = []
        if let latin = a.latinFontFamily, !latin.isEmpty { names.append(latin) }
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
