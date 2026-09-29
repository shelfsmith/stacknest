// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("G57: 電子書籍の Tab スキップの飛び先")
struct EPUBPageSkipTests {
    @Test func movesFromTheStartOfTheCurrentPages() {
        // 見開き（11–12）でも基点は左右の若い方（開始ページ）
        #expect(EPUBPageSkip.targetPage(currentStart: 11, by: 10, pageCount: 200) == 21)
        #expect(EPUBPageSkip.targetPage(currentStart: 11, by: -10, pageCount: 200) == 1)
    }
    @Test func clampsAtBothEnds() {
        #expect(EPUBPageSkip.targetPage(currentStart: 195, by: 10, pageCount: 200) == 199)
        #expect(EPUBPageSkip.targetPage(currentStart: 3, by: -10, pageCount: 200) == 0)
    }
    @Test func rejectsEmptyBook() {
        #expect(EPUBPageSkip.targetPage(currentStart: 0, by: 10, pageCount: 0) == nil)
    }
}
