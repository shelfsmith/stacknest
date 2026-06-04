// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ViewerModel")
@MainActor
struct ViewerModelTests {
    @Test func startsAtPageZero() {
        let m = ViewerModel(pageCount: 5)
        #expect(m.currentPage == 0)
        #expect(m.pageCount == 5)
    }

    @Test func advanceMovesForward() {
        let m = ViewerModel(pageCount: 5)
        m.advance()
        #expect(m.currentPage == 1)
    }

    @Test func goBackClampsAtZero() {
        let m = ViewerModel(pageCount: 5)
        m.goBack()
        #expect(m.currentPage == 0)
    }

    @Test func advanceStopsAtLastWhenStop() {
        let m = ViewerModel(pageCount: 3, options: ViewerOptions(pageDirection: .rightToLeft, endOfBookBehavior: .stop))
        m.goLast()
        #expect(m.currentPage == 2)
        m.advance()
        #expect(m.currentPage == 2)
    }

    @Test func goFirstAndGoLast() {
        let m = ViewerModel(pageCount: 10)
        m.goLast()
        #expect(m.currentPage == 9)
        m.goFirst()
        #expect(m.currentPage == 0)
    }

    @Test func goToClampsToRange() {
        let m = ViewerModel(pageCount: 5)
        m.goTo(page: 99)
        #expect(m.currentPage == 4)
        m.goTo(page: -3)
        #expect(m.currentPage == 0)
    }

    @Test func emptyBookStaysAtZero() {
        let m = ViewerModel(pageCount: 0)
        m.advance()
        #expect(m.currentPage == 0)
        m.goLast()
        #expect(m.currentPage == 0)
    }

    @Test func progressText() {
        let m = ViewerModel(pageCount: 88)
        m.goTo(page: 11)
        #expect(m.progressText == "12 / 88")
    }

    @Test func progressFraction() {
        let m = ViewerModel(pageCount: 100)
        m.goTo(page: 49)
        #expect(abs(m.progressFraction - 0.5) < 0.0001)
    }
}
