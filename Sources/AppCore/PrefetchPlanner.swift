// SPDX-License-Identifier: MIT
import Foundation

public struct PrefetchPlan: Equatable, Sendable {
    public let queue: [Int]            // 先読み順（近傍優先・有効ページ・重複なし）
    public let activeWindow: Set<Int>  // eviction 保護（cur-2..+6）
    public init(queue: [Int], activeWindow: Set<Int>) { self.queue = queue; self.activeWindow = activeWindow }
}

/// Web prefetch.js の _recompute 相当の純ロジック（content 非依存・testable）。
public enum PrefetchPlanner {
    public static func plan(current: Int, pageCount: Int, spreadPages: [Int]?,
                            neighborSpreads: [[Int]] = [], tier3: Bool) -> PrefetchPlan {
        guard pageCount > 0 else { return PrefetchPlan(queue: [], activeWindow: []) }
        let cur = max(0, min(pageCount - 1, current))
        var order: [Int] = []
        var seen = Set<Int>()
        func push(_ i: Int) { if i >= 0 && i < pageCount && seen.insert(i).inserted { order.append(i) } }
        // 前方 +1..+6 → 後方 -1..-2
        for d in 1...6 { push(cur + d) }
        for d in 1...2 { push(cur - d) }
        // 見開き前後（あれば近傍として）
        for sp in neighborSpreads { for p in sp { push(p) } }
        // スキップストライド ±10（±1 ゆらぎ込み）
        let stride = 10
        push(cur + stride); push(cur + stride + 1); push(cur + stride - 1)
        push(cur - stride); push(cur - stride + 1); push(cur - stride - 1)
        // tier3: 残り全ページを近傍優先で（現在ページ自身も含め全冊を網羅）
        if tier3 { push(cur); for d in 1..<pageCount { push(cur + d); push(cur - d) } }
        // activeWindow: cur-2..+6（＋現在見開き）
        var window = Set<Int>()
        for d in -2...6 { let i = cur + d; if i >= 0 && i < pageCount { window.insert(i) } }
        if let sp = spreadPages { for p in sp where p >= 0 && p < pageCount { window.insert(p) } }
        return PrefetchPlan(queue: order, activeWindow: window)
    }
}
