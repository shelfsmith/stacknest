// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("G51: 割合ジャンプの飛び先")
struct EPUBPercentJumpTests {
    @Test func globalPageUsesCensus() {
        #expect(EPUBPercentJump.globalPage(fraction: 0.0, pageCount: 200) == 0)
        #expect(EPUBPercentJump.globalPage(fraction: 0.5, pageCount: 200) == 100)   // (199*0.5).rounded()
        #expect(EPUBPercentJump.globalPage(fraction: 0.9, pageCount: 200) == 179)
        #expect(EPUBPercentJump.globalPage(fraction: 1.0, pageCount: 200) == 199)
    }
    @Test func globalPageClampsAndRejectsEmpty() {
        #expect(EPUBPercentJump.globalPage(fraction: 0.5, pageCount: 0) == nil)
        #expect(EPUBPercentJump.globalPage(fraction: -1, pageCount: 10) == 0)
        #expect(EPUBPercentJump.globalPage(fraction: 2, pageCount: 10) == 9)
    }
    @Test func spineFallback() {
        #expect(EPUBPercentJump.spineIndex(fraction: 0.5, spineCount: 10) == 5)     // (9*0.5).rounded() = 5
        #expect(EPUBPercentJump.spineIndex(fraction: 0.0, spineCount: 1) == 0)
        #expect(EPUBPercentJump.spineIndex(fraction: 0.5, spineCount: 0) == nil)
    }
}
