// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("PrefetchPlanner")
struct PrefetchPlannerTests {
    @Test func forwardBeforeBackward() {
        let p = PrefetchPlanner.plan(current: 20, pageCount: 100, spreadPages: nil, tier3: false)
        let iFwd = p.queue.firstIndex(of: 21)!
        let iBack = p.queue.firstIndex(of: 19)!
        #expect(iFwd < iBack)                 // 前方 +1 が 後方 -1 より先
        #expect(Array(p.queue.prefix(6)) == [21,22,23,24,25,26])  // 前方 +1..+6 が先頭
    }
    @Test func includesSkipStride() {
        let p = PrefetchPlanner.plan(current: 20, pageCount: 100, spreadPages: nil, tier3: false)
        #expect(p.queue.contains(30))         // +10
        #expect(p.queue.contains(10))         // -10
    }
    @Test func activeWindowIsNearRange() {
        let p = PrefetchPlanner.plan(current: 20, pageCount: 100, spreadPages: nil, tier3: false)
        #expect(p.activeWindow == Set(18...26))   // cur-2..+6
    }
    @Test func clampsAtEdges() {
        let p = PrefetchPlanner.plan(current: 0, pageCount: 3, spreadPages: nil, tier3: false)
        #expect(p.queue.allSatisfy { $0 >= 0 && $0 < 3 })
        #expect(Set(p.queue).count == p.queue.count)   // 重複なし
        #expect(p.activeWindow == Set([0,1,2]))
    }
    @Test func tier3CoversAllPagesNearFirst() {
        let p = PrefetchPlanner.plan(current: 5, pageCount: 50, spreadPages: nil, tier3: true)
        #expect(Set(p.queue) == Set(0..<50))         // 全ページ包含
        #expect(Array(p.queue.prefix(6)) == [6,7,8,9,10,11])  // 近傍優先
    }
    @Test func backwardDirectionPrioritizesBackward() {
        // G18 案A: 後方送り（direction<0）では後方 -1..-6 が先頭・前方 +1..+2 が後。
        let p = PrefetchPlanner.plan(current: 20, pageCount: 100, spreadPages: nil, tier3: false, direction: -1)
        #expect(Array(p.queue.prefix(6)) == [19,18,17,16,15,14])  // 後方 -1..-6 が先頭
        let iBack = p.queue.firstIndex(of: 19)!
        let iFwd = p.queue.firstIndex(of: 21)!
        #expect(iBack < iFwd)                            // 後方 -1 が 前方 +1 より先
        #expect(p.activeWindow == Set(14...22))          // cur-6..+2（後方側を深く保護）
    }
    @Test func forwardDirectionMatchesDefault() {
        // direction 既定(+1)は従来と同一挙動（前方送りは A1/A2 の回帰を避けるため不変）。
        let d = PrefetchPlanner.plan(current: 20, pageCount: 100, spreadPages: nil, tier3: false)
        let f = PrefetchPlanner.plan(current: 20, pageCount: 100, spreadPages: nil, tier3: false, direction: 1)
        #expect(d.queue == f.queue)
        #expect(d.activeWindow == f.activeWindow)
    }
    @Test func spreadModeExpandsNeighbors() {
        let p = PrefetchPlanner.plan(current: 4, pageCount: 100, spreadPages: [4,5],
                                     neighborSpreads: [[2,3],[6,7]], tier3: false)
        #expect(p.queue.contains(6)); #expect(p.queue.contains(7))  // 次見開き
        #expect(p.queue.contains(2)); #expect(p.queue.contains(3))  // 前見開き
    }
}
