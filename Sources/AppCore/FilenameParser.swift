// SPDX-License-Identifier: MIT
import Foundation

/// title (主) / filename (fallback) から series + volume を抽出した結果。
///
/// 既存 title を変更しない。series / volume のみ返す。
public struct ParsedMetadata: Equatable {
    public let series: String?
    public let volume: Double?

    public init(series: String?, volume: Double?) {
        self.series = series
        self.volume = volume
    }
}

/// title (主) / filename (fallback) から series + volume を抽出する純関数。
///
/// 仕様要点:
/// - 既存 title を変更しない (parser の戻り値は series / volume のみ)
/// - 空欄 (NULL/empty) の場合のみ補完、既存値は上書きしない (呼び出し側責務)
/// - 各種数字表記 (アラビア / 漢 / ローマ / ギリシャ) は NumeralNormalizer 経由で Double 化
/// - 「上中下」は title 単体で文脈判定 (上下 2 巻 vs 上中下 3 巻)
public enum FilenameParser {
    /// title 優先で抽出、volume が取れなければ filename (拡張子除く) を fallback として試行。
    public static func parse(title: String, filename: String?) -> ParsedMetadata {
        if let r = extract(from: title), r.volume != nil {
            return r
        }
        if let fn = filename, !fn.isEmpty {
            let base = (fn as NSString).deletingPathExtension
            if let r = extract(from: base), r.volume != nil {
                return r
            }
        }
        return ParsedMetadata(series: nil, volume: nil)
    }

    // MARK: - 抽出ロジック

    /// 任意の単一文字列から series + volume を試みる。volume が抽出できない場合は nil を返す。
    private static func extract(from input: String) -> ParsedMetadata? {
        // NUMERAL token (alternation)
        // 注: ASCII ローマ [IVXLCDM]+ は context 内 (第N巻/Vol./末尾括弧) でのみ使われるため
        //     誤検出を抑制できる。bare token での単独マッチは行わない。
        let numeralPattern = #"([0-9０-９]+(?:[.．][0-9０-９]+)?|[〇零一二三四五六七八九十百千壱弐参肆伍陸柒捌玖拾佰仟]+|[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹⅺⅻ]|[IVXLCDM]+|[αβγδεζηθικλμνξοπρστυφχψω])"#

        let patterns: [String] = [
            #"第\s*"# + numeralPattern + #"\s*巻"#,      // 「第5巻」「第三巻」「第Ⅴ巻」「第0巻」「第零巻」
            #"[Vv]ol[\s.]*"# + numeralPattern,           // 「Vol.7」「Vol.Ⅴ」
            #"[Vv]olume\s*"# + numeralPattern,           // 「Volume 3」
            #"\("# + numeralPattern + #"\)$"#,           // 末尾の「(12)」「(壱)」
            #"\s+"# + numeralPattern + #"$"#             // 末尾の「 8」「 α」
        ]

        for pat in patterns {
            if let (range, captured) = firstMatch(input: input, pattern: pat),
               let volume = NumeralNormalizer.toDouble(captured) {
                let prefix = String(input[input.startIndex..<range.lowerBound])
                let series = trimSeriesCandidate(prefix)
                return ParsedMetadata(series: series, volume: volume)
            }
        }
        // 上中下 (context 判定)
        if let r = parseJoChuGe(input) { return r }
        return nil
    }

    /// 正規表現の最初のマッチを返す。capture group 1 を文字列として返す。
    private static func firstMatch(input: String, pattern: String) -> (Range<String.Index>, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let m = regex.firstMatch(in: input, options: [], range: range) else { return nil }
        guard let fullRange = Range(m.range, in: input),
              m.numberOfRanges >= 2,
              let capRange = Range(m.range(at: 1), in: input) else { return nil }
        return (fullRange, String(input[capRange]))
    }

    /// 「上巻」「中巻」「下巻」を 1/2/3 にマップ。
    /// 中巻がタイトルにあれば 3 巻構成と判定し、上=1/中=2/下=3。
    /// 中巻がなければ上下 2 巻構成で、上=1/下=2。
    private static func parseJoChuGe(_ input: String) -> ParsedMetadata? {
        let hasJou = input.range(of: #"上\s*巻"#, options: .regularExpression) != nil
        let hasChuu = input.range(of: #"中\s*巻"#, options: .regularExpression) != nil
        let hasGe = input.range(of: #"下\s*巻"#, options: .regularExpression) != nil

        let threeVolume = hasChuu

        var volume: Double?
        var rangePattern: String?
        if hasJou {
            volume = 1.0
            rangePattern = #"上\s*巻"#
        } else if hasChuu {
            volume = 2.0
            rangePattern = #"中\s*巻"#
        } else if hasGe {
            volume = threeVolume ? 3.0 : 2.0
            rangePattern = #"下\s*巻"#
        }
        guard let v = volume,
              let pat = rangePattern,
              let r = input.range(of: pat, options: .regularExpression) else { return nil }
        let prefix = String(input[input.startIndex..<r.lowerBound])
        let series = trimSeriesCandidate(prefix)
        return ParsedMetadata(series: series, volume: v)
    }

    /// title から volume 抽出範囲を除いた前半を trim して series 候補に。
    private static func trimSeriesCandidate(_ s: String) -> String? {
        let separators = CharacterSet.whitespaces.union(.init(charactersIn: "-_/:\u{3000}"))
        let trim = s.trimmingCharacters(in: separators)
        return trim.isEmpty ? nil : trim
    }
}
