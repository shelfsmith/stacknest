// SPDX-License-Identifier: MIT
import Testing
import LibraryServerAPI
@testable import StackNest

@Suite("G56-S1: 破損チェックの結果の表示")
struct IntegrityRowsTextTests {
    @Test func errorMarkerIsTranslatedForDisplay() {
        // テストは日本語に固定（-testLanguage ja）
        #expect(IntegrityRowsText.display([IntegrityCheckDTO.errorRow]) == "(エラー)")
    }
    @Test func legacyServerValuesAreTranslatedToo() {
        #expect(IntegrityRowsText.display(["(Error)"]) == "(エラー)")
        #expect(IntegrityRowsText.display(["(エラー)"]) == "(エラー)")
    }
    @Test func otherRowsPassThroughAndAreCapped() {
        let rows = (1...25).map { "row \($0)" }
        let shown = IntegrityRowsText.display(rows).split(separator: "\n")
        #expect(shown.count == 20)
        #expect(shown.first == "row 1")
    }
}
