// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import StackroomFormat

@Suite("FilenameFormatter forward")
struct FilenameFormatterForwardTests {
    private let stackroomDefault = "(@genre) [@keywordB] [@author] @title"

    @Test
    func allFieldsFilled() throws {
        let f = try FilenameFormat(raw: stackroomDefault)
        let r = makeRecord(title: "ハイスコアガール", author: "押切蓮介",
                           genre: "マンガ", keywordB: "名作", bookType: 0)
        #expect(FilenameFormatter.format(r, with: f) == "(マンガ) [名作] [押切蓮介] ハイスコアガール")
    }

    @Test
    func emptyKeywordBracketGroupOmitted() throws {
        let f = try FilenameFormat(raw: stackroomDefault)
        let r = makeRecord(title: "Foo", author: "Y", genre: "M",
                           keywordB: nil, bookType: 0)
        #expect(FilenameFormatter.format(r, with: f) == "(M) [Y] Foo")
    }

    @Test
    func allFieldsEmptyExceptTitle() throws {
        let f = try FilenameFormat(raw: stackroomDefault)
        let r = makeRecord(title: "Solo", bookType: 0)
        #expect(FilenameFormatter.format(r, with: f) == "Solo")
    }

    @Test
    func colonReplacedWithFullwidth() throws {
        let f = try FilenameFormat(raw: "@title")
        let r = makeRecord(title: "A:B", bookType: 0)
        #expect(FilenameFormatter.format(r, with: f) == "A：B")
    }

    @Test
    func slashAndBackslashReplaced() throws {
        let f = try FilenameFormat(raw: "@title")
        let r = makeRecord(title: "a/b\\c|d", bookType: 0)
        #expect(FilenameFormatter.format(r, with: f) == "a／b￥c｜d")
    }

    @Test
    func nullByteRemoved() throws {
        let f = try FilenameFormat(raw: "@title")
        let r = makeRecord(title: "a\0b", bookType: 0)
        #expect(FilenameFormatter.format(r, with: f) == "ab")
    }

    private func makeRecord(
        title: String,
        author: String? = nil,
        genre: String? = nil,
        keywordB: String? = nil,
        bookType: Int = 1
    ) -> BookRecord {
        BookRecord(
            id: 0,
            title: title,
            author: author,
            genre: genre,
            coverImagePath: "",
            dateAdded: Date(),
            bookType: bookType,
            keywordB: keywordB
        )
    }
}

@Suite("FilenameFormatter reverse")
struct FilenameFormatterReverseTests {
    private let stackroomDefault = "(@genre) [@keywordB] [@author] @title"

    @Test
    func allFieldsRecovered() throws {
        let f = try FilenameFormat(raw: stackroomDefault)
        let r = FilenameFormatter.parse("(マンガ) [名作] [押切蓮介] ハイスコアガール", with: f)
        #expect(r.matched == true)
        #expect(r.fields[.genre] == "マンガ")
        #expect(r.fields[.keywordB] == "名作")
        #expect(r.fields[.author] == "押切蓮介")
        #expect(r.fields[.title] == "ハイスコアガール")
    }

    @Test
    func optionalGroupsCanBeMissing() throws {
        let f = try FilenameFormat(raw: stackroomDefault)
        let r = FilenameFormatter.parse("(マンガ) Foo", with: f)
        #expect(r.matched == true)
        #expect(r.fields[.genre] == "マンガ")
        #expect(r.fields[.title] == "Foo")
        #expect(r.fields[.keywordB] == nil)
        #expect(r.fields[.author] == nil)
    }

    @Test
    func plainBasenameMatchesWithAllOptionalBrackets() throws {
        // "random_name_123" has no (genre) or [author] brackets.
        // All bracketGroup segments are optional; their inter-bracket whitespace literals are
        // also elided when all brackets are absent. @title consumes the full string verbatim.
        let f = try FilenameFormat(raw: stackroomDefault)
        let r = FilenameFormatter.parse("random_name_123", with: f)
        #expect(r.matched == true)
        #expect(r.fields[.title] == "random_name_123")
        #expect(r.fields[.author] == nil)
        #expect(r.fields[.genre] == nil)
    }

    @Test
    func makeRecordFromBasename() throws {
        let f = try FilenameFormat(raw: stackroomDefault)
        let r = FilenameFormatter.makeBookFields(fromBasename: "random_name_123", with: f)
        // matched=true (all brackets optional) ⇒ title from @title token = "random_name_123"
        #expect(r[.title] == "random_name_123")
        #expect(r[.author] == nil)
    }

    @Test
    func extensionStrippedForFallback() throws {
        // makeBookFields callers are expected to pass a basename WITHOUT extension.
        // parse() no longer strips extensions internally (to avoid "Naruto Vol.7" → "Naruto Vol").
        // This test verifies that a stem containing a dot (e.g., a caller that accidentally passes
        // an extension-like suffix) is parsed verbatim — the @title token takes the whole string.
        let f = try FilenameFormat(raw: stackroomDefault)
        let r = FilenameFormatter.makeBookFields(fromBasename: "random.zip", with: f)
        // All brackets optional; @title captures "random.zip" verbatim (no internal extension strip)
        #expect(r[.title] == "random.zip")
    }

    @Test
    func interleavedBracketsFirstPresentSecondAbsent() throws {
        let f = try FilenameFormat(raw: "[@keywordB] [@author] @title")
        // keywordB matched ("名作"), author missing, title at end ("Foo")
        let r = FilenameFormatter.parse("[名作] Foo", with: f)
        #expect(r.matched == true)
        #expect(r.fields[.keywordB] == "名作")
        #expect(r.fields[.author] == nil)
        #expect(r.fields[.title] == "Foo")
    }

    /// Fix 2: BookAddCoordinator must use basename verbatim as title, not fields[.title].
    /// The FilenameFormatter may parse "Naruto Vol.7" with a format that has a trailing
    /// literal suffix, causing fields[.title] to not equal the full basename.
    @Test
    func makeBookFieldsTitleMayNotBeBasenameVerbatim() throws {
        // Use a format where @title consumes up to a known literal ("[@author]") at the end.
        // A basename like "Naruto [Kishimoto]" will have title="Naruto" (without the bracket part).
        // This demonstrates why BookAddCoordinator must use basename directly as the book title.
        let format = try FilenameFormat(raw: "@title [@author]")
        let fields = FilenameFormatter.makeBookFields(fromBasename: "Naruto [Kishimoto]", with: format)
        // The format matches and splits: title="Naruto", author="Kishimoto"
        // The book title should be "Naruto [Kishimoto]" (full basename), not "Naruto"
        #expect(fields[.title] != "Naruto [Kishimoto]",
                "Expected formatter to split basename — shows why basename must be used directly")
        #expect(fields[.title] == "Naruto")
    }

    @Test
    func interleavedBracketsFirstAbsentSecondPresent() throws {
        // Greedy left-to-right: when only one [..] group is present in the input and two
        // bracketGroup slots exist in the format ([@keywordB] then [@author]), the first
        // slot claims the bracket. "押切" goes to keywordB, author remains nil.
        // Note: the forward formatter produces identical filenames for
        //   {keywordB:"押切", author:nil} and {keywordB:nil, author:"押切"} — the round-trip
        //   is inherently ambiguous; greedy left-to-right is the defined tie-break.
        let f = try FilenameFormat(raw: "[@keywordB] [@author] @title")
        let r = FilenameFormatter.parse("[押切] Foo", with: f)
        #expect(r.matched == true)
        #expect(r.fields[.keywordB] == "押切")
        #expect(r.fields[.author] == nil)
        #expect(r.fields[.title] == "Foo")
    }
}
