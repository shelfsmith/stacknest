// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

// MARK: - Contract
//
// `localizedSortKey` produces ICU binary sort keys whose byte-lexicographic order
// equals Foundation's `localized*Compare` **for realistic library data**
// (Japanese / Latin titles, numbered series names, volume labels).
//
// KNOWN, ACCEPTED DIVERGENCES (user decision 2026-06-05 — "ICUキー採用"):
// ICU sort keys cannot byte-exactly reproduce `localizedStandardCompare` /
// `localizedCaseInsensitiveCompare` for the following pathological Unicode inputs,
// which do not occur in book/series titles:
//   1. Compatibility ligatures / forms (ﬀ ﬁ ½ Ⅷ …)
//   2. Numeric runs longer than ICU's colNumeric precision (~20+ digits)
//   3. Precomposed-vs-decomposed sequences mixed with combining marks (e.g. か+゛ vs が)
// On these classes the keyed order may differ from Foundation. This is intentional
// and the cost of a ~10x sort speedup. The realistic-data guarantee below is the
// contract callers rely on; `realisticCorpusMatchesLocalized` is its regression guard.

@Suite("localizedSortKey — ICU keys; byte order matches localized*Compare for realistic data")
struct LocalizedSortKeyTests {
    /// バイト辞書比較の符号
    private func cmp(_ a: [UInt8], _ b: [UInt8]) -> ComparisonResult {
        if a.lexicographicallyPrecedes(b) { return .orderedAscending }
        if b.lexicographicallyPrecedes(a) { return .orderedDescending }
        return .orderedSame
    }

    @Test func numericNaturalOrder() {
        // "シリーズ2" < "シリーズ10"（数値自然順）
        let k2 = localizedSortKey("シリーズ2", numeric: true)
        let k10 = localizedSortKey("シリーズ10", numeric: true)
        #expect(cmp(k2, k10) == "シリーズ2".localizedStandardCompare("シリーズ10"))
        #expect(cmp(k2, k10) == .orderedAscending)
    }

    @Test func caseInsensitiveEqual() {
        let kA = localizedSortKey("ABC", numeric: false)
        let ka = localizedSortKey("abc", numeric: false)
        #expect(cmp(kA, ka) == "ABC".localizedCaseInsensitiveCompare("abc"))
        #expect(cmp(kA, ka) == .orderedSame)
    }

    @Test func matchesLocalizedAcrossPairs() {
        let samples = ["りんご", "リンゴ", "Apple", "apple", "本2", "本10", "本1",
                       "ﾊﾝｶｸ", "全角", "ABC10", "ABC2", "", " z", "あ"]
        for a in samples { for b in samples {
            // numeric=true は localizedStandardCompare と一致
            #expect(cmp(localizedSortKey(a, numeric: true), localizedSortKey(b, numeric: true))
                    == a.localizedStandardCompare(b), "std mismatch: \(a) vs \(b)")
            // numeric=false は localizedCaseInsensitiveCompare と一致
            #expect(cmp(localizedSortKey(a, numeric: false), localizedSortKey(b, numeric: false))
                    == a.localizedCaseInsensitiveCompare(b), "ci mismatch: \(a) vs \(b)")
        }}
    }

    /// 現実的な書誌データ（和洋タイトル・数字入りシリーズ名・巻数ラベル）の全ペアで、
    /// ICU キーのバイト順が localized*Compare と完全一致することを保証する回帰ガード。
    /// これがこの関数の「契約」。病的入力（上記コメント参照）は対象外。
    @Test func realisticCorpusMatchesLocalized() {
        let corpus = [
            "ワンピース", "ONE PIECE", "ナルト", "NARUTO", "鬼滅の刃", "進撃の巨人",
            "ドラゴンボール", "シリーズ1", "シリーズ2", "シリーズ10", "シリーズ20",
            "ガンダム0079", "ガンダム0083", "Akira", "AKIRA", "美味しんぼ",
            "こちら葛飾区亀有公園前派出所", "Vol.1", "Vol.2", "Vol.10",
            "第1巻", "第2巻", "第10巻", "第1部", "第2部", "第10部",
            "BLEACH", "ブリーチ", "スラムダンク", "SLAM DUNK", "名探偵コナン",
            "Dr.スランプ", "北斗の拳", "20世紀少年", "21世紀少年", "3月のライオン",
            "five", "Five", "FIVE", "apple", "Apple", "りんご", "リンゴ", "", " "
        ]
        for a in corpus { for b in corpus {
            #expect(cmp(localizedSortKey(a, numeric: true), localizedSortKey(b, numeric: true))
                    == a.localizedStandardCompare(b), "std mismatch (realistic): \(a) vs \(b)")
            #expect(cmp(localizedSortKey(a, numeric: false), localizedSortKey(b, numeric: false))
                    == a.localizedCaseInsensitiveCompare(b), "ci mismatch (realistic): \(a) vs \(b)")
        }}
    }
}
