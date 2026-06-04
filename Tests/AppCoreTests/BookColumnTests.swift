// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

@Suite struct BookColumnTests {
    @Test func allCasesContains14Columns() {
        #expect(BookColumn.allCases.count == 14)
    }

    @Test func titleAlwaysVisible() {
        #expect(BookColumn.title.alwaysVisible)
        for col in BookColumn.allCases where col != .title {
            #expect(col.alwaysVisible == false)
        }
    }

    @Test func defaultEnabledColumns() {
        let defaults: Set<BookColumn> = [.title, .rating, .author, .genre, .dateAdded, .playDate]
        for col in BookColumn.allCases {
            #expect(col.defaultEnabled == defaults.contains(col))
        }
    }

    @Test func roundTripCodable() throws {
        let cols: Set<BookColumn> = [.title, .rating, .neta, .keywordB]
        let data = try JSONEncoder().encode(cols)
        let back = try JSONDecoder().decode(Set<BookColumn>.self, from: data)
        #expect(back == cols)
    }
}
