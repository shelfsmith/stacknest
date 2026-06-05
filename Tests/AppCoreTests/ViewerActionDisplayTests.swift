// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("ViewerAction display metadata")
struct ViewerActionDisplayTests {
    @Test func everyActionHasNonEmptyName() {
        for a in ViewerAction.allCases { #expect(!a.displayName.isEmpty) }
    }
    @Test func sectionsCoverAllActionsExactlyOnce() {
        let listed = ViewerActionSection.allCases.flatMap { $0.actions }
        #expect(Set(listed) == Set(ViewerAction.allCases), "全 action がいずれかのセクションに属す")
        #expect(listed.count == ViewerAction.allCases.count, "重複なし")
    }
    @Test func knownLabels() {
        #expect(ViewerAction.nextPage.displayName == "ページ送り")
        #expect(ViewerAction.close.displayName == "閉じる")
    }
}
