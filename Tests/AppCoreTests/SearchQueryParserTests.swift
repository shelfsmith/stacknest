// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("SearchQueryParser")
struct SearchQueryParserTests {
    @Test func hashDigitsParsesID() { #expect(SearchQueryParser.bookID(from: "#123") == 123) }
    @Test func surroundingSpacesTrimmed() { #expect(SearchQueryParser.bookID(from: "  #  12 ") == 12) }
    @Test func plainTextIsNil() { #expect(SearchQueryParser.bookID(from: "abc") == nil) }
    @Test func hashOnlyIsNil() { #expect(SearchQueryParser.bookID(from: "#") == nil) }
    @Test func hashWithLettersIsNil() { #expect(SearchQueryParser.bookID(from: "#12a") == nil) }
    @Test func emptyIsNil() { #expect(SearchQueryParser.bookID(from: "") == nil) }
    @Test func noHashNumberIsNil() { #expect(SearchQueryParser.bookID(from: "123") == nil) }
}
