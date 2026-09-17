// SPDX-License-Identifier: MIT
import Foundation
import Testing
import EPUBAdapter
@testable import AppCore

@Suite("G54-S3: ページ送りの演出を掛けるか")
struct PageTurnDecisionTests {
    private func plan(_ style: PageTurnStyleValue = .slide, reduceMotion: Bool = false,
                      elapsed: TimeInterval = 1.0, forward: Bool = true, rtl: Bool = true) -> PageTurnPlan? {
        PageTurnDecision.plan(style: style, reduceMotion: reduceMotion, secondsSinceLastTurn: elapsed,
                              forward: forward, rightToLeft: rtl)
    }

    @Test func offNeverAnimates() { #expect(plan(.off) == nil) }

    @Test func reduceMotionNeverAnimates() { #expect(plan(reduceMotion: true) == nil) }

    @Test func rapidTurnsAreNotAnimated() {
        #expect(plan(elapsed: 0.1) == nil)
        #expect(plan(elapsed: 0.3) == nil)          // 境界ちょうどは演出しない（Washi は > 0.3）
        #expect(plan(elapsed: 0.31) != nil)
    }

    @Test func fadeReturnsAPlan() {
        #expect(plan(.fade)?.style == .fade)
    }

    /// Washi と同じ式: direction = (forward ? 1 : -1) * (isRTL ? 1 : -1)、正なら右へ。
    @Test func slideDirectionMatchesWashi() {
        #expect(plan(forward: true, rtl: true)?.slideTowardRight == true)
        #expect(plan(forward: true, rtl: false)?.slideTowardRight == false)
        #expect(plan(forward: false, rtl: true)?.slideTowardRight == false)
        #expect(plan(forward: false, rtl: false)?.slideTowardRight == true)
    }

    @Test func timingsMatchWashi() {
        #expect(PageTurnDecision.duration == 0.22)
        #expect(PageTurnDecision.minimumInterval == 0.3)
    }
}
