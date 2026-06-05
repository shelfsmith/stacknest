// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("localizedSortKey — byte order matches localized*Compare")
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
}
