// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackroomFormat

@Suite("LegacyConditionsConverter")
struct LegacyConditionsConverterTests {
    @Test func dateAddedWithin() {
        // 実データ: Condition="Date Added", Key=30, Option=0
        let legacy = PlaylistConditions(
            dateCondition: DateCondition(condition: "Date Added", key: 30, option: 0),
            rateCondition: nil, keywordCondition: nil)
        let c = LegacyConditionsConverter.convert(legacy)
        #expect(c.match == .all)
        #expect(c.rules.count == 1)
        let r = c.rules[0]
        #expect(r.field == .dateAdded)
        #expect(r.op == .within)
        #expect(r.value.asDays == 30)
    }

    @Test func playDateOlderThan() {
        let legacy = PlaylistConditions(
            dateCondition: DateCondition(condition: "Play Date", key: 7, option: 1),
            rateCondition: nil, keywordCondition: nil)
        let r = LegacyConditionsConverter.convert(legacy).rules[0]
        #expect(r.field == .playDate)
        #expect(r.op == .olderThan)
        #expect(r.value.asDays == 7)
    }

    @Test func rateOptionMapping() {
        let gte = LegacyConditionsConverter.convert(PlaylistConditions(
            dateCondition: nil, rateCondition: RateCondition(value: 3, option: 0), keywordCondition: nil)).rules[0]
        #expect(gte.field == .rating); #expect(gte.op == .gte); #expect(gte.value.asInt == 3)

        let lte = LegacyConditionsConverter.convert(PlaylistConditions(
            dateCondition: nil, rateCondition: RateCondition(value: 4, option: 1), keywordCondition: nil)).rules[0]
        #expect(lte.op == .lte)

        let eq = LegacyConditionsConverter.convert(PlaylistConditions(
            dateCondition: nil, rateCondition: RateCondition(value: 5, option: 2), keywordCondition: nil)).rules[0]
        #expect(eq.op == .eq)

        // 未知 Option はフォールバック .gte
        let fallback = LegacyConditionsConverter.convert(PlaylistConditions(
            dateCondition: nil, rateCondition: RateCondition(value: 2, option: 99), keywordCondition: nil)).rules[0]
        #expect(fallback.op == .gte)
    }

    @Test func keywordContainsFallback() {
        let r = LegacyConditionsConverter.convert(PlaylistConditions(
            dateCondition: nil, rateCondition: nil,
            keywordCondition: KeywordCondition(value: "foo", option: 0))).rules[0]
        #expect(r.field == .keywordA)
        #expect(r.op == .contains)
        #expect(r.value.asText == "foo")
    }

    @Test func multipleConditionsCombineAsAll() {
        let legacy = PlaylistConditions(
            dateCondition: DateCondition(condition: "Date Added", key: 10, option: 0),
            rateCondition: RateCondition(value: 3, option: 0),
            keywordCondition: KeywordCondition(value: "bar", option: 0))
        let c = LegacyConditionsConverter.convert(legacy)
        #expect(c.match == .all)
        #expect(c.rules.count == 3)
    }

    @Test func emptyConditionsProducesNoRules() {
        let c = LegacyConditionsConverter.convert(
            PlaylistConditions(dateCondition: nil, rateCondition: nil, keywordCondition: nil))
        #expect(c.match == .all)
        #expect(c.rules.isEmpty)
    }

    @Test func convertedConditionsHaveVersion1() {
        let c = LegacyConditionsConverter.convert(
            PlaylistConditions(dateCondition: DateCondition(condition: "Date Added", key: 5, option: 0),
                               rateCondition: nil, keywordCondition: nil))
        #expect(c.version == 1)
    }
}
