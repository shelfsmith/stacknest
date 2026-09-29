// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("G57: 電子書籍の Tab スキップの飛び先")
struct EPUBPageSkipTests {
    @Test func movesFromTheStartOfTheCurrentPages() {
        // 見開き（11–12）でも基点は左右の若い方（開始ページ）
        #expect(EPUBPageSkip.targetPage(currentRange: 11...12, by: 10, pageCount: 200) == 21)
        #expect(EPUBPageSkip.targetPage(currentRange: 11...12, by: -10, pageCount: 200) == 1)
    }
    /// 見開きで 1 ページだけ動かすときは、今の見開きの外へ出す（右側のページを指すと同じ見開きに戻る）。
    @Test func alwaysLeavesTheCurrentSpread() {
        #expect(EPUBPageSkip.targetPage(currentRange: 40...41, by: 1, pageCount: 200) == 42)
        #expect(EPUBPageSkip.targetPage(currentRange: 40...41, by: -1, pageCount: 200) == 39)
        #expect(EPUBPageSkip.targetPage(currentRange: 40...40, by: 1, pageCount: 200) == 41)
        #expect(EPUBPageSkip.targetPage(currentRange: 40...40, by: -1, pageCount: 200) == 39)
    }
    @Test func clampsAtBothEnds() {
        #expect(EPUBPageSkip.targetPage(currentRange: 195...196, by: 10, pageCount: 200) == 199)
        #expect(EPUBPageSkip.targetPage(currentRange: 3...3, by: -10, pageCount: 200) == 0)
        #expect(EPUBPageSkip.targetPage(currentRange: 198...199, by: 1, pageCount: 200) == 199)
        #expect(EPUBPageSkip.targetPage(currentRange: 0...1, by: -1, pageCount: 200) == 0)
    }
    @Test func rejectsEmptyBook() {
        #expect(EPUBPageSkip.targetPage(currentRange: 0...0, by: 10, pageCount: 0) == nil)
    }
}
