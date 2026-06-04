// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import StackroomFormat

/// Regression tests for BookAddCoordinator title resolution.
///
/// Fix context (Phase 2.5c-a fix-up v5):
/// Commit 312e33d introduced `resolvedTitle = basename` unconditionally, breaking custom filename
/// format title extraction. The correct logic is: use fields[.title] when non-nil/non-empty,
/// fall back to basename otherwise.
///
/// These tests verify FilenameFormatter.makeBookFields behavior for both cases,
/// providing the ground-truth that BookAddCoordinator should rely on.
@Suite("BookAddCoordinator title resolution")
struct BookAddTitleResolutionTests {

    // MARK: - Fix B: custom format extracts title field correctly

    /// Custom format `(@genre) [@author] @title` correctly extracts title from a Japanese manga filename.
    /// Scenario: user has set filename_format to "(@genre) [@author] @title"
    /// File: "(一般コミック) [たかたけし] 住みにごり 第10巻.zip"
    /// Expected: fields[.title] = "住みにごり 第10巻" (NOT the full basename)
    @Test
    func customFormatExtractsTitleField() throws {
        let format = try FilenameFormat(raw: "(@genre) [@author] @title")
        let fields = FilenameFormatter.makeBookFields(
            fromBasename: "(一般コミック) [たかたけし] 住みにごり 第10巻",
            with: format
        )
        #expect(fields[.title] == "住みにごり 第10巻")
        #expect(fields[.genre] == "一般コミック")
        #expect(fields[.author] == "たかたけし")
    }

    /// Same test using the Stackroom default format which also has `@title` at the end.
    /// File: "(マンガ) [名作] [押切蓮介] ハイスコアガール"
    @Test
    func defaultFormatExtractsTitleField() throws {
        let defaultFormat = try FilenameFormat(raw: "(@genre) [@keywordB] [@author] @title")
        let fields = FilenameFormatter.makeBookFields(
            fromBasename: "(マンガ) [名作] [押切蓮介] ハイスコアガール",
            with: defaultFormat
        )
        #expect(fields[.title] == "ハイスコアガール")
        #expect(fields[.genre] == "マンガ")
        #expect(fields[.author] == "押切蓮介")
    }

    // MARK: - Naruto Vol.7 regression check

    /// Verifies that "Naruto Vol.7" is parsed correctly after fixing the double-strip bug.
    ///
    /// Fix: FilenameFormatter.parse() no longer calls deletingPathExtension internally.
    /// BookAddCoordinator passes `url.deletingPathExtension().lastPathComponent` as basename,
    /// so "Naruto Vol.7.cbz" → basename = "Naruto Vol.7", which is now parsed verbatim.
    /// All bracket groups are optional in the default format, so @title consumes the full
    /// basename "Naruto Vol.7" correctly.
    @Test
    func narutoBehavior_noDoubleStripAfterFix() throws {
        // BookAddCoordinator passes `url.deletingPathExtension().lastPathComponent` as basename.
        // For "Naruto Vol.7.cbz" that means basename = "Naruto Vol.7".
        // After fix: parse() does NOT strip extension internally → title = "Naruto Vol.7" ✓
        let defaultFormat = try FilenameFormat(raw: "(@genre) [@keywordB] [@author] @title")
        let fields = FilenameFormatter.makeBookFields(fromBasename: "Naruto Vol.7", with: defaultFormat)
        #expect(fields[.title] == "Naruto Vol.7",
                "After fix: 'Naruto Vol.7' is parsed verbatim as title (no double-strip)")
    }

    /// Confirms that for a properly formatted filename (custom format), fields[.title] is correct
    /// and does NOT suffer from double-strip because the title contains no dot-segments.
    @Test
    func customFormat_noDoubleStripIssue() throws {
        // "住みにごり 第10巻" has no dot → deletingPathExtension is a no-op → title is correct
        let format = try FilenameFormat(raw: "(@genre) [@author] @title")
        let fields = FilenameFormatter.makeBookFields(
            fromBasename: "(一般コミック) [たかたけし] 住みにごり 第10巻",
            with: format
        )
        #expect(fields[.title] == "住みにごり 第10巻",
                "Title without dot is correctly extracted by custom format")
    }

    // MARK: - Correct resolvedTitle logic validation

    /// Validates the correct conditional logic that BookAddCoordinator should use:
    /// `fields[.title]` when non-nil and non-empty, otherwise `basename`.
    /// This test documents the expected behavior for both formatted and unformatted filenames.
    @Test
    func resolvedTitleLogicForCustomFormat() throws {
        let format = try FilenameFormat(raw: "(@genre) [@author] @title")

        // Case 1: formatted filename → use fields[.title]
        let formattedBasename = "(一般コミック) [たかたけし] 住みにごり 第10巻"
        let formattedFields = FilenameFormatter.makeBookFields(fromBasename: formattedBasename, with: format)
        let resolvedFormatted: String
        if let fieldTitle = formattedFields[.title], !fieldTitle.isEmpty {
            resolvedFormatted = fieldTitle
        } else {
            resolvedFormatted = formattedBasename
        }
        #expect(resolvedFormatted == "住みにごり 第10巻",
                "Custom format: resolvedTitle should use extracted title, not full basename")

        // Case 2: unformatted filename → fallback to basename
        let unfmtBasename = "SomeBook"
        let unfmtFields = FilenameFormatter.makeBookFields(fromBasename: unfmtBasename, with: format)
        let resolvedUnformatted: String
        if let fieldTitle = unfmtFields[.title], !fieldTitle.isEmpty {
            resolvedUnformatted = fieldTitle
        } else {
            resolvedUnformatted = unfmtBasename
        }
        // "SomeBook" matches format (genre/author both optional, title="SomeBook") → fields[.title]="SomeBook"
        // Either way, resolvedTitle == basename in this case
        #expect(resolvedUnformatted == "SomeBook")
    }
}
