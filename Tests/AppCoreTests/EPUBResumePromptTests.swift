// SPDX-License-Identifier: MIT
import Testing
import EPUBAdapter
@testable import AppCore

@Suite("G54-S3b: EPUB を開くとき続きから訊くか")
struct EPUBResumePromptTests {
    private func loc(_ spine: Int, _ progress: Double) -> EPUBLocatorValue {
        EPUBLocatorValue(spine: spine, progress: progress, cfi: nil, engine: nil)
    }

    @Test func noSavedPositionDoesNotAsk() {
        #expect(EPUBResumePrompt.shouldAsk(locator: nil) == false)
    }

    @Test func theVeryBeginningDoesNotAsk() {
        #expect(EPUBResumePrompt.shouldAsk(locator: loc(0, 0)) == false)
    }

    @Test func progressWithinTheFirstItemAsks() {
        #expect(EPUBResumePrompt.shouldAsk(locator: loc(0, 0.3)) == true)
    }

    @Test func laterItemAsksEvenAtItsBeginning() {
        #expect(EPUBResumePrompt.shouldAsk(locator: loc(2, 0)) == true)
    }

    /// `EPUBLocatorValue` の init が負の値を 0 に丸めるので、先頭と同じ扱いになる。
    @Test func negativeValuesAreTreatedAsTheBeginning() {
        #expect(EPUBResumePrompt.shouldAsk(locator: loc(-1, -0.5)) == false)
    }
}
