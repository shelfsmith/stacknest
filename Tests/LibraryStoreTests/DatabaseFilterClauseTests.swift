// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

@Suite("buildFilterClause")
struct DatabaseFilterClauseTests {
    @Test func emptyFilterReturnsEmptyClause() {
        let (sql, args) = Database.buildFilterClause(FilterState())
        #expect(sql == "")
        #expect(args.isEmpty)
    }

    @Test func bookTypesSingle() {
        var f = FilterState()
        f.bookTypes = [3]
        let (sql, args) = Database.buildFilterClause(f)
        #expect(sql == " AND b.book_type IN (?)")
        #expect(args.count == 1)
        #expect((args[0] as? Int) == 3)
    }

    @Test func bookTypesMultipleSorted() {
        var f = FilterState()
        f.bookTypes = [2, 0, 5]
        let (sql, args) = Database.buildFilterClause(f)
        #expect(sql == " AND b.book_type IN (?,?,?)")
        #expect((args[0] as? Int) == 0)
        #expect((args[1] as? Int) == 2)
        #expect((args[2] as? Int) == 5)
    }

    @Test func unseenUnreadOnly() {
        var f = FilterState()
        f.unseen = .unreadOnly
        let (sql, args) = Database.buildFilterClause(f)
        #expect(sql == " AND b.unseen = ?")
        #expect((args[0] as? Int) == 1)
    }

    @Test func unseenReadOnly() {
        var f = FilterState()
        f.unseen = .readOnly
        let (_, args) = Database.buildFilterClause(f)
        #expect((args[0] as? Int) == 0)
    }

    @Test func ratingMinPositive() {
        var f = FilterState()
        f.ratingMin = 3
        let (sql, args) = Database.buildFilterClause(f)
        #expect(sql == " AND b.rating >= ?")
        #expect((args[0] as? Int) == 3)
    }

    @Test func ratingMinZeroBecomesEquality() {
        var f = FilterState()
        f.ratingMin = 0
        let (sql, args) = Database.buildFilterClause(f)
        #expect(sql == " AND b.rating = 0")
        #expect(args.isEmpty)
    }

    @Test func dateAddedWithin() {
        var f = FilterState()
        f.dateAdded = .init(direction: .within, days: 7)
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let (sql, args) = Database.buildFilterClause(f, now: now)
        #expect(sql == " AND b.date_added >= ?")
        let expected = 1_000_000_000.0 - 7.0 * 86_400.0
        #expect((args[0] as? Double) == expected)
    }

    @Test func dateAddedOlderThan() {
        var f = FilterState()
        f.dateAdded = .init(direction: .olderThan, days: 30)
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let (sql, args) = Database.buildFilterClause(f, now: now)
        #expect(sql == " AND b.date_added < ?")
        let expected = 1_000_000_000.0 - 30.0 * 86_400.0
        #expect((args[0] as? Double) == expected)
    }

    @Test func playDateUsesPlayDateColumn() {
        var f = FilterState()
        f.playDate = .init(direction: .within, days: 14)
        let (sql, _) = Database.buildFilterClause(f, now: Date())
        #expect(sql == " AND b.play_date >= ?")
    }

    @Test func combinedFilters() {
        var f = FilterState()
        f.bookTypes = [0, 1]
        f.unseen = .unreadOnly
        f.ratingMin = 2
        let (sql, args) = Database.buildFilterClause(f)
        #expect(sql == " AND b.book_type IN (?,?) AND b.unseen = ? AND b.rating >= ?")
        #expect(args.count == 4)
    }
}
