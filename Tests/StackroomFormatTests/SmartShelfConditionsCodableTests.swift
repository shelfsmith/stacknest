// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackroomFormat

@Suite("SmartShelfConditions Codable")
struct SmartShelfConditionsCodableTests {
    @Test func roundTripAllFieldsAndValues() throws {
        let conditions = SmartShelfConditions(
            match: .any,
            rules: [
                SmartShelfRule(id: UUID(), field: .genre, op: .contains, value: .text("コミック")),
                SmartShelfRule(id: UUID(), field: .rating, op: .gte, value: .int(3)),
                SmartShelfRule(id: UUID(), field: .dateAdded, op: .within, value: .days(30)),
                SmartShelfRule(id: UUID(), field: .unseen, op: .isUnread, value: .int(0)),
            ]
        )
        let data = try JSONEncoder().encode(conditions)
        let decoded = try JSONDecoder().decode(SmartShelfConditions.self, from: data)
        #expect(decoded == conditions)
        #expect(decoded.version == 1)
    }

    @Test func ruleValueEncodesTaggedKind() throws {
        let data = try JSONEncoder().encode(RuleValue.days(7))
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"kind\""))
        #expect(json.contains("\"kind\":\"days\"") || json.contains("\"kind\" : \"days\""))
    }

    @Test func unknownRuleValueKindThrows() {
        let badJSON = #"{"kind":"weird","value":1}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RuleValue.self, from: badJSON)
        }
    }
}
