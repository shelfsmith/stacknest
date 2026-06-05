// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("ViewerHelpRows generation")
struct ViewerHelpRowsTests {
    @Test func defaultsProduceRowForEveryAction() {
        let rows = ViewerHelpRows.make(from: .defaults)
        #expect(rows.count == ViewerAction.allCases.count)
    }
    @Test func nextPageRowShowsItsKeys() {
        let rows = ViewerHelpRows.make(from: .defaults)
        let row = rows.first { $0.action == ViewerAction.nextPage.displayName }
        #expect(row != nil)
        #expect(row!.keys.contains("Space"))
        #expect(row!.keys.contains("↓"))
    }
    @Test func reassignmentIsReflected() {
        var b = ViewerKeyBindings(map: [:], characterMap: [:])
        _ = b.assign(.character("z"), to: .nextPage)
        let rows = ViewerHelpRows.make(from: b)
        let row = rows.first { $0.action == ViewerAction.nextPage.displayName }!
        #expect(row.keys == "z")
    }
    @Test func unboundActionShowsDash() {
        let b = ViewerKeyBindings(map: [:], characterMap: [:])
        let rows = ViewerHelpRows.make(from: b)
        #expect(rows.allSatisfy { $0.keys == "—" })
    }
}
