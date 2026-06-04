// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore
import StackroomFormat

@Suite("buildSmartShelfClause")
struct SmartShelfClauseTests {
    private func rule(_ f: SmartShelfRule.Field, _ o: SmartShelfRule.Operator, _ v: RuleValue) -> SmartShelfRule {
        SmartShelfRule(id: UUID(), field: f, op: o, value: v)
    }

    @Test func emptyRulesMatchNothing() {
        let c = SmartShelfConditions(match: .all, rules: [])
        let (sql, args) = Database.buildSmartShelfClause(c)
        #expect(sql == " AND 0")
        #expect(args.isEmpty)
    }

    @Test func singleTextContains() {
        let c = SmartShelfConditions(match: .all, rules: [rule(.genre, .contains, .text("コミック"))])
        let (sql, args) = Database.buildSmartShelfClause(c)
        #expect(sql == " AND (b.genre LIKE ? ESCAPE '\\')")
        #expect((args[0] as? String) == "%コミック%")
    }

    @Test func textStartsAndEndsWith() {
        let starts = Database.buildSmartShelfClause(
            SmartShelfConditions(match: .all, rules: [rule(.title, .startsWith, .text("ab"))]))
        #expect((starts.args[0] as? String) == "ab%")
        let ends = Database.buildSmartShelfClause(
            SmartShelfConditions(match: .all, rules: [rule(.title, .endsWith, .text("ab"))]))
        #expect((ends.args[0] as? String) == "%ab")
    }

    @Test func textContainsEscapesLikeSpecialChars() {
        // %, _ , \ は escapeLikePattern で escape され、リテラル一致になる
        let c = SmartShelfConditions(match: .all, rules: [rule(.title, .contains, .text("50%_a\\b"))])
        let (sql, args) = Database.buildSmartShelfClause(c)
        #expect(sql == " AND (b.title LIKE ? ESCAPE '\\')")
        #expect((args[0] as? String) == "%50\\%\\_a\\\\b%")
    }

    @Test func textEqualsUsesMultiValue4Pattern() {
        let c = SmartShelfConditions(match: .all, rules: [rule(.author, .equals, .text("X"))])
        let (sql, _) = Database.buildSmartShelfClause(c)
        #expect(sql.contains("b.author = ?"))
        #expect(sql.contains("b.author LIKE ?"))
    }

    @Test func numericOperators() {
        #expect(Database.buildSmartShelfClause(
            SmartShelfConditions(match: .all, rules: [rule(.rating, .gte, .int(3))])).whereSQL
            == " AND (b.rating >= ?)")
        #expect(Database.buildSmartShelfClause(
            SmartShelfConditions(match: .all, rules: [rule(.pages, .lte, .int(100))])).whereSQL
            == " AND (b.pages <= ?)")
        #expect(Database.buildSmartShelfClause(
            SmartShelfConditions(match: .all, rules: [rule(.bookType, .eq, .int(1))])).whereSQL
            == " AND (b.book_type = ?)")
    }

    @Test func unseenNoArgs() {
        let unread = Database.buildSmartShelfClause(
            SmartShelfConditions(match: .all, rules: [rule(.unseen, .isUnread, .int(0))]))
        #expect(unread.whereSQL == " AND (b.unseen = 1)")
        #expect(unread.args.isEmpty)
        let read = Database.buildSmartShelfClause(
            SmartShelfConditions(match: .all, rules: [rule(.unseen, .isRead, .int(0))]))
        #expect(read.whereSQL == " AND (b.unseen = 0)")
    }

    @Test func dateWithinUsesCutoff() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let c = SmartShelfConditions(match: .all, rules: [rule(.dateAdded, .within, .days(1))])
        let (sql, args) = Database.buildSmartShelfClause(c, now: now)
        #expect(sql == " AND (b.date_added >= ?)")
        #expect((args[0] as? Double) == 1_000_000.0 - 86_400.0)
    }

    @Test func dateOlderThanUsesLessThan() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let c = SmartShelfConditions(match: .all, rules: [rule(.playDate, .olderThan, .days(2))])
        let (sql, args) = Database.buildSmartShelfClause(c, now: now)
        #expect(sql == " AND (b.play_date < ?)")
        #expect((args[0] as? Double) == 1_000_000.0 - 2.0 * 86_400.0)
    }

    @Test func multipleRulesAllUsesAnd() {
        let c = SmartShelfConditions(match: .all, rules: [
            rule(.rating, .gte, .int(3)), rule(.bookType, .eq, .int(1))])
        #expect(Database.buildSmartShelfClause(c).whereSQL == " AND (b.rating >= ? AND b.book_type = ?)")
    }

    @Test func multipleRulesAnyUsesOr() {
        let c = SmartShelfConditions(match: .any, rules: [
            rule(.rating, .gte, .int(3)), rule(.bookType, .eq, .int(1))])
        #expect(Database.buildSmartShelfClause(c).whereSQL == " AND (b.rating >= ? OR b.book_type = ?)")
    }
}
