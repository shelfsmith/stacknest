// SPDX-License-Identifier: MIT
import Foundation

/// キャッシュ済みページ集合を、プログレスバー描画用の [start, end]（0..1 割合）帯にまとめる純ロジック。
/// ページ i は [i/n, (i+1)/n] を占める。連続ページは 1 本の帯にマージする。
public enum CacheCoverage {
    public static func segments(cached: Set<Int>, pageCount: Int) -> [ClosedRange<Double>] {
        guard pageCount > 0 else { return [] }
        let pages = cached.filter { $0 >= 0 && $0 < pageCount }.sorted()
        guard !pages.isEmpty else { return [] }
        let n = Double(pageCount)
        var result: [ClosedRange<Double>] = []
        var runStart = pages[0]
        var runEnd = pages[0]
        for p in pages.dropFirst() {
            if p == runEnd + 1 {
                runEnd = p
            } else {
                result.append(Double(runStart) / n ... Double(runEnd + 1) / n)
                runStart = p; runEnd = p
            }
        }
        result.append(Double(runStart) / n ... Double(runEnd + 1) / n)
        return result
    }
}
