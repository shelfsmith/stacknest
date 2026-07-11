// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("GridNavigator paging & range")
struct GridNavigatorPagingTests {
    @Test func pageDownMovesByColumnsTimesRows() {
        // columns 3 × rows 4 = 12 進む
        #expect(GridNavigator.pageIndex(current: 0, total: 100, columns: 3, rows: 4, up: false) == 12)
    }
    @Test func pageUpMovesBack() {
        #expect(GridNavigator.pageIndex(current: 12, total: 100, columns: 3, rows: 4, up: true) == 0)
    }
    @Test func pageUpClampsAtTop() {
        #expect(GridNavigator.pageIndex(current: 2, total: 100, columns: 3, rows: 4, up: true) == 0)
    }
    @Test func pageDownClampsAtBottom() {
        #expect(GridNavigator.pageIndex(current: 95, total: 100, columns: 3, rows: 4, up: false) == 99)
    }
    @Test func pageInvalidInputReturnsNil() {
        #expect(GridNavigator.pageIndex(current: 0, total: 0, columns: 3, rows: 4, up: false) == nil)
        #expect(GridNavigator.pageIndex(current: 0, total: 100, columns: 0, rows: 4, up: false) == nil)
    }
    @Test func rangeAscending() {
        #expect(GridNavigator.rangeIndices(anchor: 2, target: 5) == [2, 3, 4, 5])
    }
    @Test func rangeDescendingNormalizes() {
        #expect(GridNavigator.rangeIndices(anchor: 5, target: 2) == [2, 3, 4, 5])
    }
    @Test func rangeSingle() {
        #expect(GridNavigator.rangeIndices(anchor: 3, target: 3) == [3])
    }
}
