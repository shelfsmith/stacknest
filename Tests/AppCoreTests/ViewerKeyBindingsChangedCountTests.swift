// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

/// G54-S1: キー割り当ての折りたたみ見出しに「（N 件変更）」を出すための計数。
@Suite("G54-S1: 節ごとの変更件数")
struct ViewerKeyBindingsChangedCountTests {
    @Test func defaultsHaveNoChanges() {
        let b = ViewerKeyBindings.defaults
        for section in ViewerActionSection.allCases {
            #expect(b.changedCount(in: section) == 0, "\(section.title) は既定なら 0")
        }
    }

    @Test func reassigningCountsOnlyInItsOwnSection() {
        var b = ViewerKeyBindings.defaults
        _ = b.assign(.character("z"), to: .nextPage)          // nextPage は navigation
        #expect(b.changedCount(in: .navigation) == 1)
        for section in ViewerActionSection.allCases where section != .navigation {
            #expect(b.changedCount(in: section) == 0)
        }
    }

    @Test func removingADefaultKeyCountsAsChanged() {
        var b = ViewerKeyBindings.defaults
        b.remove(.chord(KeyChord(keyCode: 49)), from: .nextPage)   // Space を外す
        #expect(b.changedCount(in: .navigation) == 1)
    }

    @Test func unbindingEveryKeyOfAnActionCountsOnce() {
        var b = ViewerKeyBindings.defaults
        for capture in ViewerKeyBindings.defaults.boundBindings(for: .nextPage) {
            b.remove(capture, from: .nextPage)
        }
        #expect(b.changedCount(in: .navigation) == 1)
    }

    @Test func resetAllClearsTheCounts() {
        var b = ViewerKeyBindings.defaults
        _ = b.assign(.character("z"), to: .nextPage)
        _ = b.assign(.character("y"), to: .toggleSpread)       // spreadSlideshow
        #expect(b.changedCount(in: .navigation) == 1)
        #expect(b.changedCount(in: .spreadSlideshow) == 1)
        b.resetAll()
        for section in ViewerActionSection.allCases {
            #expect(b.changedCount(in: section) == 0)
        }
    }

    @Test func twoChangesInOneSectionCountTwo() {
        var b = ViewerKeyBindings.defaults
        _ = b.assign(.character("z"), to: .nextPage)
        _ = b.assign(.character("x"), to: .previousPage)        // どちらも navigation
        #expect(b.changedCount(in: .navigation) == 2)
    }
}
