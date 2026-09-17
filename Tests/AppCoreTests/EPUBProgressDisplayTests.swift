// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("G54-S3: EPUB の HUD の文字と割合")
struct EPUBProgressDisplayTests {
    @Test func singlePageAfterCensus() {
        let d = EPUBProgressDisplay.make(globalPageCount: 340, currentGlobalPageRange: 11...11,
                                         spineIndex: 2, spineProgress: 0.1, spineCount: 8)
        #expect(d == EPUBProgressDisplay(text: "12 / 340", fraction: 12.0 / 340.0))
    }

    @Test func spreadAfterCensusUsesFirstPageForFraction() {
        let d = EPUBProgressDisplay.make(globalPageCount: 340, currentGlobalPageRange: 11...12,
                                         spineIndex: 2, spineProgress: 0.1, spineCount: 8)
        #expect(d == EPUBProgressDisplay(text: "12–13 / 340", fraction: 12.0 / 340.0))
    }

    @Test func measuringUsesSpineApproximation() {
        let d = EPUBProgressDisplay.make(globalPageCount: nil, currentGlobalPageRange: nil,
                                         spineIndex: 1, spineProgress: 0.5, spineCount: 4)
        #expect(d == EPUBProgressDisplay(text: "計測中…", fraction: 0.375))
    }

    @Test func countWithoutRangeIsStillMeasuring() {
        let d = EPUBProgressDisplay.make(globalPageCount: 340, currentGlobalPageRange: nil,
                                         spineIndex: 0, spineProgress: 0, spineCount: 4)
        #expect(d.text == EPUBProgressDisplay.measuringText)
        #expect(d.fraction == 0)
    }

    @Test func lastChapterEndIsOne() {
        let d = EPUBProgressDisplay.make(globalPageCount: nil, currentGlobalPageRange: nil,
                                         spineIndex: 3, spineProgress: 1.0, spineCount: 4)
        #expect(d.fraction == 1.0)
    }

    @Test func outOfRangeInputsAreClamped() {
        let over = EPUBProgressDisplay.make(globalPageCount: nil, currentGlobalPageRange: nil,
                                            spineIndex: 9, spineProgress: 2.0, spineCount: 4)
        #expect(over.fraction == 1.0)
        let pastEnd = EPUBProgressDisplay.make(globalPageCount: 10, currentGlobalPageRange: 12...13,
                                               spineIndex: nil, spineProgress: nil, spineCount: nil)
        #expect(pastEnd == EPUBProgressDisplay(text: "10 / 10", fraction: 1.0))
    }

    @Test func nothingKnownYet() {
        let d = EPUBProgressDisplay.make(globalPageCount: nil, currentGlobalPageRange: nil,
                                         spineIndex: nil, spineProgress: nil, spineCount: nil)
        #expect(d == EPUBProgressDisplay(text: "計測中…", fraction: 0))
        let zero = EPUBProgressDisplay.make(globalPageCount: 0, currentGlobalPageRange: 0...0,
                                            spineIndex: nil, spineProgress: nil, spineCount: 0)
        #expect(zero == EPUBProgressDisplay(text: "計測中…", fraction: 0))
    }
}
