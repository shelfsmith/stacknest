// SPDX-License-Identifier: MIT
import Foundation

public struct PrefetchPlan: Equatable, Sendable {
    public let queue: [Int]            // 先読み順（近傍優先・有効ページ・重複なし）
    public let activeWindow: Set<Int>  // eviction 保護（cur-2..+6）
    public init(queue: [Int], activeWindow: Set<Int>) { self.queue = queue; self.activeWindow = activeWindow }
}

/// Web prefetch.js の _recompute 相当の純ロジック（content 非依存・testable）。
public enum PrefetchPlanner {
    /// - Parameter direction: 直近のページ送り方向。`>= 0` で前方優先（既定）、`< 0` で後方優先。
    ///   G18 smoke fix（案A）: 矢印長押しで先読みが「めくる先」を先にデコードし切れるよう、
    ///   進行方向側を深さ 6・逆側を深さ 2 で優先する（従来は方向に関わらず常に前方優先だった）。
    public static func plan(current: Int, pageCount: Int, spreadPages: [Int]?,
                            neighborSpreads: [[Int]] = [], tier3: Bool, direction: Int = 1) -> PrefetchPlan {
        guard pageCount > 0 else { return PrefetchPlan(queue: [], activeWindow: []) }
        let cur = max(0, min(pageCount - 1, current))
        // 進行方向の符号（+1 前方 / -1 後方）。0 は前方扱い。
        let primary = direction < 0 ? -1 : 1
        var order: [Int] = []
        var seen = Set<Int>()
        func push(_ i: Int) { if i >= 0 && i < pageCount && seen.insert(i).inserted { order.append(i) } }
        // 進行方向 +1..+6 → 逆方向 -1..-2（primary で符号反転）
        for d in 1...6 { push(cur + primary * d) }
        for d in 1...2 { push(cur - primary * d) }
        // 見開き前後（あれば近傍として）
        for sp in neighborSpreads { for p in sp { push(p) } }
        // スキップストライド ±10（±1 ゆらぎ込み）
        let stride = 10
        push(cur + stride); push(cur + stride + 1); push(cur + stride - 1)
        push(cur - stride); push(cur - stride + 1); push(cur - stride - 1)
        // tier3: 残り全ページを近傍優先で（現在ページ自身も含め全冊を網羅）
        if tier3 { push(cur); for d in 1..<pageCount { push(cur + d); push(cur - d) } }
        // activeWindow: 進行方向側を深く保護（前方なら cur-2..+6／後方なら cur-6..+2）＋現在見開き
        let backSpan = primary < 0 ? 6 : 2
        let fwdSpan  = primary < 0 ? 2 : 6
        var window = Set<Int>()
        for d in -backSpan...fwdSpan { let i = cur + d; if i >= 0 && i < pageCount { window.insert(i) } }
        if let sp = spreadPages { for p in sp where p >= 0 && p < pageCount { window.insert(p) } }
        return PrefetchPlan(queue: order, activeWindow: window)
    }
}
