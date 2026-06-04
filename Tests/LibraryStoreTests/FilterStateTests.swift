// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("FilterState")
struct FilterStateTests {
    @Test func defaultIsEmpty() {
        let f = FilterState()
        #expect(f.isEmpty == true)
        #expect(f.activeCount == 0)
    }

    @Test func bookTypesActiveBumpsCount() {
        var f = FilterState()
        f.bookTypes = [0, 1]
        #expect(f.isEmpty == false)
        #expect(f.activeCount == 1)
    }

    @Test func unseenActiveBumpsCount() {
        var f = FilterState()
        f.unseen = .unreadOnly
        #expect(f.activeCount == 1)
    }

    @Test func ratingMinZeroIsActive() {
        var f = FilterState()
        f.ratingMin = 0
        #expect(f.isEmpty == false)
        #expect(f.activeCount == 1)
    }

    @Test func dateConditionsCountSeparately() {
        var f = FilterState()
        f.dateAdded = .init(direction: .within, days: 7)
        f.playDate = .init(direction: .olderThan, days: 30)
        #expect(f.activeCount == 2)
    }

    @Test func dateConditionDaysClampedToOne() {
        let r = FilterState.DateRangeCondition(direction: .within, days: 0)
        #expect(r.days == 1)
        let r2 = FilterState.DateRangeCondition(direction: .within, days: -5)
        #expect(r2.days == 1)
    }

    @Test func codableRoundTrip() throws {
        var f = FilterState()
        f.bookTypes = [0, 2, 4]
        f.unseen = .unreadOnly
        f.ratingMin = 3
        f.dateAdded = .init(direction: .within, days: 7)
        f.playDate = .init(direction: .olderThan, days: 30)
        let data = try JSONEncoder().encode(f)
        let decoded = try JSONDecoder().decode(FilterState.self, from: data)
        #expect(decoded == f)
    }

    @Test func equatable() {
        var a = FilterState()
        let b = FilterState()
        #expect(a == b)
        a.ratingMin = 3
        #expect(a != b)
        var c = FilterState()
        c.ratingMin = 3
        #expect(a == c)
    }
}
