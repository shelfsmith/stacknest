// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import StackroomFormat

@Suite("FormatToken")
struct FormatTokenTests {
    @Test
    func parsesAllKnownTokens() throws {
        #expect(FormatToken(raw: "@title") == .title)
        #expect(FormatToken(raw: "@author") == .author)
        #expect(FormatToken(raw: "@genre") == .genre)
        #expect(FormatToken(raw: "@keywordA") == .keywordA)
        #expect(FormatToken(raw: "@keywordB") == .keywordB)
        #expect(FormatToken(raw: "@relation") == .relation)
        #expect(FormatToken(raw: "@type") == .type)
    }

    @Test
    func unknownTokenReturnsNil() throws {
        #expect(FormatToken(raw: "@unknown") == nil)
        #expect(FormatToken(raw: "title") == nil)         // missing @
        #expect(FormatToken(raw: "@") == nil)
    }

    @Test
    func valueInRecordReturnsField() throws {
        let r = makeRecord(title: "Foo", author: "押切", genre: nil, keywordA: nil,
                           keywordB: "名作", neta: nil, bookType: 1)
        #expect(FormatToken.title.value(in: r) == "Foo")
        #expect(FormatToken.author.value(in: r) == "押切")
        #expect(FormatToken.genre.value(in: r) == nil)
        #expect(FormatToken.keywordB.value(in: r) == "名作")
    }

    @Test
    func typeRendersLocalizedLabel() throws {
        let r = makeRecord(title: "Foo", bookType: 3)
        // 3 = 画像セット (0-based convention)
        #expect(FormatToken.type.value(in: r) == "画像セット")
    }

    private func makeRecord(
        title: String, author: String? = nil, genre: String? = nil,
        keywordA: String? = nil, keywordB: String? = nil, neta: String? = nil,
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
            keywordA: keywordA,
            keywordB: keywordB,
            neta: neta
        )
    }
}

@Suite("FilenameFormat parser")
struct FilenameFormatParserTests {
    @Test
    func emptyStringProducesEmptySegments() throws {
        let f = try FilenameFormat(raw: "")
        #expect(f.segments == [])
    }

    @Test
    func parsesSimpleLiteralAndToken() throws {
        let f = try FilenameFormat(raw: "@title")
        #expect(f.segments == [.token(.title)])
    }

    @Test
    func parsesStackroomDefault() throws {
        let f = try FilenameFormat(raw: "(@genre) [@keywordB] [@author] @title")
        #expect(f.segments == [
            .bracketGroup(open: "(", body: [.token(.genre)], close: ")"),
            .literal(" "),
            .bracketGroup(open: "[", body: [.token(.keywordB)], close: "]"),
            .literal(" "),
            .bracketGroup(open: "[", body: [.token(.author)], close: "]"),
            .literal(" "),
            .token(.title)
        ])
    }

    @Test
    func bracketGroupWithMixedContent() throws {
        let f = try FilenameFormat(raw: "[@author - @title]")
        #expect(f.segments == [
            .bracketGroup(
                open: "[",
                body: [.token(.author), .literal(" - "), .token(.title)],
                close: "]"
            )
        ])
    }

    @Test
    func unknownTokenThrows() throws {
        #expect(throws: FilenameFormat.ParseError.self) {
            _ = try FilenameFormat(raw: "@unknown")
        }
    }

    @Test
    func unclosedBracketThrows() throws {
        #expect(throws: FilenameFormat.ParseError.self) {
            _ = try FilenameFormat(raw: "[@title")
        }
    }

    @Test
    func nestedBracketThrows() throws {
        #expect(throws: FilenameFormat.ParseError.self) {
            _ = try FilenameFormat(raw: "[[@title]]")
        }
    }
}
