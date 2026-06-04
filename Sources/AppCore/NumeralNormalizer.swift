// SPDX-License-Identifier: MIT
import Foundation

/// 数字を表す文字列を Double に正規化する純関数。
///
/// 対応表記:
/// - アラビア (半/全角、小数点): `5`, `5.5`, `５`, `５．５`, `0`, `０`
/// - 漢数字 0: `〇`, `零`
/// - 漢数字 通常: `一` 〜 `十`, `十一`, `二十`, `二十一`, `百`, `千`
/// - 漢数字 旧字体: `壱`, `弐`, `参`, `肆`, `伍`, `陸`, `柒`, `捌`, `玖`, `拾`, `佰`, `仟`
/// - ローマ Unicode: `Ⅰ` 〜 `Ⅻ`, 小文字 `ⅰ` 〜 `ⅻ`
/// - ローマ ASCII: `I`, `II`, …, `MMMCMXCIX` (1-3999)
/// - ギリシャ小文字: `α` 〜 `ω` (1-24)
///
/// 「上中下」は context 判定 (上下 2 巻 vs 上中下 3 巻) が必要なため、本モジュールでは扱わない。
/// FilenameParser が title 単体で文脈判定する。
public enum NumeralNormalizer {
    /// 数字を表す文字列を Double に正規化。解釈不能なら nil。
    public static func toDouble(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let d = parseArabic(trimmed) { return d }
        if let d = parseKanji(trimmed) { return d }
        if let d = parseRomanUnicode(trimmed) { return d }
        if let d = parseRomanASCII(trimmed) { return d }
        if let d = parseGreek(trimmed) { return d }
        return nil
    }

    // MARK: - Arabic

    private static func parseArabic(_ s: String) -> Double? {
        var normalized = ""
        for ch in s {
            if let scalar = ch.unicodeScalars.first {
                let v = scalar.value
                if v >= 0xFF10 && v <= 0xFF19 {  // ０-９
                    normalized.append(Character(UnicodeScalar(v - 0xFF10 + 0x30)!))
                } else if v == 0xFF0E {  // ．
                    normalized.append(".")
                } else {
                    normalized.append(ch)
                }
            }
        }
        return Double(normalized)
    }

    // MARK: - Kanji

    private static let kanjiDigit: [Character: Double] = [
        "〇": 0, "零": 0,
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9,
        "壱": 1, "弐": 2, "参": 3, "肆": 4, "伍": 5,
        "陸": 6, "柒": 7, "捌": 8, "玖": 9
    ]
    private static let kanjiPower: [Character: Double] = [
        "十": 10, "百": 100, "千": 1000,
        "拾": 10, "佰": 100, "仟": 1000
    ]

    /// 漢数字 (単独 0-9、桁 (十百千)、複合 「十一」「二十」「二十一」)。
    private static func parseKanji(_ s: String) -> Double? {
        // 含まれる全文字が漢数字 (digit + power) のみであることを要求
        for ch in s where kanjiDigit[ch] == nil && kanjiPower[ch] == nil {
            return nil
        }
        // 単一文字
        if s.count == 1, let d = kanjiDigit[s.first!] { return d }
        if s.count == 1, let p = kanjiPower[s.first!] { return p }

        // 複合: 「digit*power+digit?」(例: 二十一 = 2*10 + 1)
        var total: Double = 0
        var current: Double = 0
        for ch in s {
            if let d = kanjiDigit[ch] {
                current = d
            } else if let p = kanjiPower[ch] {
                total += (current == 0 ? 1 : current) * p
                current = 0
            }
        }
        return total + current
    }

    // MARK: - Roman Unicode

    private static let romanUnicode: [Character: Double] = [
        "Ⅰ": 1, "Ⅱ": 2, "Ⅲ": 3, "Ⅳ": 4, "Ⅴ": 5,
        "Ⅵ": 6, "Ⅶ": 7, "Ⅷ": 8, "Ⅸ": 9, "Ⅹ": 10,
        "Ⅺ": 11, "Ⅻ": 12,
        "ⅰ": 1, "ⅱ": 2, "ⅲ": 3, "ⅳ": 4, "ⅴ": 5,
        "ⅵ": 6, "ⅶ": 7, "ⅷ": 8, "ⅸ": 9, "ⅹ": 10,
        "ⅺ": 11, "ⅻ": 12
    ]
    private static func parseRomanUnicode(_ s: String) -> Double? {
        guard s.count == 1, let ch = s.first, let d = romanUnicode[ch] else { return nil }
        return d
    }

    // MARK: - Roman ASCII

    private static let romanASCIIValue: [Character: Int] = [
        "I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000
    ]
    private static func parseRomanASCII(_ s: String) -> Double? {
        guard !s.isEmpty, s.allSatisfy({ romanASCIIValue[$0] != nil }) else { return nil }
        var total = 0
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            let v = romanASCIIValue[ch]!
            if i + 1 < chars.count, let next = romanASCIIValue[chars[i + 1]], next > v {
                total -= v
            } else {
                total += v
            }
        }
        return total > 0 ? Double(total) : nil
    }

    // MARK: - Greek

    private static let greekValue: [Character: Double] = {
        let letters: [Character] = ["α","β","γ","δ","ε","ζ","η","θ","ι","κ","λ","μ",
                                     "ν","ξ","ο","π","ρ","σ","τ","υ","φ","χ","ψ","ω"]
        var m: [Character: Double] = [:]
        for (i, ch) in letters.enumerated() {
            m[ch] = Double(i + 1)
        }
        return m
    }()
    private static func parseGreek(_ s: String) -> Double? {
        guard s.count == 1, let ch = s.first, let d = greekValue[ch] else { return nil }
        return d
    }
}
