// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import StackroomFormat

/// Tests for Phase 2.7F: @type token should honor custom bookType label overrides.
@Suite("FilenameFormatter @type label override")
struct FilenameTypeLabelTests {

    // bookType 0 = "厚い本" (canonical)
    @Test func typeTokenDefaultsToCanonical() throws {
        let fmt = try FilenameFormat(raw: "@type")
        let rec = BookRecord(id: 0, title: "Foo", dateAdded: Date(), bookType: 0)
        #expect(FilenameFormatter.format(rec, with: fmt) == "厚い本")
    }

    @Test func typeTokenUsesCustomOverride() throws {
        let fmt = try FilenameFormat(raw: "@type")
        let rec = BookRecord(id: 0, title: "Foo", dateAdded: Date(), bookType: 0)
        #expect(FilenameFormatter.format(rec, with: fmt, bookTypeLabels: [0: "長編"]) == "長編")
    }

    @Test func typeTokenOverrideAbsentFallsBackToCanonical() throws {
        let fmt = try FilenameFormat(raw: "@type")
        // bookType 1 = "薄い本", override only provides key 0
        let rec = BookRecord(id: 0, title: "Foo", dateAdded: Date(), bookType: 1)
        #expect(FilenameFormatter.format(rec, with: fmt, bookTypeLabels: [0: "長編"]) == "薄い本")
    }

    @Test func typeTokenOutOfRangeReturnsNilEvenWithOverrides() throws {
        let fmt = try FilenameFormat(raw: "@type")
        let rec = BookRecord(id: 0, title: "Foo", dateAdded: Date(), bookType: 99)
        // Out-of-range bookType with no override for key 99 → nil → empty string
        #expect(FilenameFormatter.format(rec, with: fmt, bookTypeLabels: [0: "長編"]) == "")
    }

    @Test func typeInBracketGroupOmittedWhenCustomLabelEmpty() throws {
        // An empty-string override should NOT count as a value (empty ⇒ treated as nil)
        let fmt = try FilenameFormat(raw: "[@type] @title")
        let rec = BookRecord(id: 0, title: "MyBook", dateAdded: Date(), bookType: 99)
        // 99 has no canonical label and no override → bracketGroup omitted
        #expect(FilenameFormatter.format(rec, with: fmt) == "MyBook")
    }

    @Test func typeInBracketGroupRenderedWithCustomLabel() throws {
        let fmt = try FilenameFormat(raw: "[@type] @title")
        let rec = BookRecord(id: 0, title: "MyBook", dateAdded: Date(), bookType: 2)
        #expect(FilenameFormatter.format(rec, with: fmt, bookTypeLabels: [2: "同人誌"]) == "[同人誌] MyBook")
    }

    @Test func existingTestsUnchanged_allFieldsFilled() throws {
        // Existing test from FilenameFormatterTests must still pass with default (no override)
        let fmt = try FilenameFormat(raw: "(@genre) [@keywordB] [@author] @title")
        let rec = BookRecord(
            id: 0, title: "ハイスコアガール", author: "押切蓮介",
            genre: "マンガ", dateAdded: Date(), bookType: 0, keywordB: "名作"
        )
        #expect(FilenameFormatter.format(rec, with: fmt) == "(マンガ) [名作] [押切蓮介] ハイスコアガール")
    }
}
