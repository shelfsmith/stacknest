// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("LabelCustomization — effectiveLabel + bookType canonical")
struct LabelCustomizationTests {

    @Test func overrideNilReturnsDefault() {
        #expect(effectiveLabel(default: "ジャンル", override: nil) == "ジャンル")
    }

    @Test func overrideEmptyReturnsDefault() {
        #expect(effectiveLabel(default: "ジャンル", override: "") == "ジャンル")
    }

    @Test func overrideNonEmptyWins() {
        #expect(effectiveLabel(default: "ジャンル", override: "サークル") == "サークル")
    }

    @Test func bookTypeCanonicalLabelsCount() {
        #expect(BookTypeLabel.canonicalLabels.count == 6)
        #expect(BookTypeLabel.canonicalLabel(for: 0) == "厚い本")
        #expect(BookTypeLabel.canonicalLabel(for: 5) == "ムービー")
    }

    @Test func bookTypeCanonicalLabelOutOfRangeIsEmpty() {
        #expect(BookTypeLabel.canonicalLabel(for: 99) == "")
        #expect(BookTypeLabel.canonicalLabel(for: -1) == "")
    }

    @Test func bookTypeLegacyLabelMatchesCanonical() {
        for i in 0..<6 {
            #expect(BookTypeLabel.label(for: i) == BookTypeLabel.canonicalLabel(for: i))
        }
    }
}
