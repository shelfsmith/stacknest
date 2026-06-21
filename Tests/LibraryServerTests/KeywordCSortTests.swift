// SPDX-License-Identifier: MIT
import Testing
@testable import LibraryServer

@Suite("BookSortKey keywordC")
struct KeywordCSortTests {
    @Test func keywordCIsValidSortKey() {
        #expect(BookSortKey(rawValue: "keywordC") == .keywordC)
    }
}
