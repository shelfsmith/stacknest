// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("BrowserPaneState")
struct BrowserPaneStateTests {
    @Test func defaultIsThreeColumnsAllUnselected() {
        let s = BrowserPaneState()
        #expect(s.fields == [.genre, .author, .keywordA])
        #expect(s.selections == [nil, nil, nil])
        #expect(s.height == 200)
    }

    @Test func setFieldClearsSelectionsFromIndexOnward() {
        var s = BrowserPaneState()
        s.selections = ["a", "b", "c"]
        s.setField(.keywordB, at: 1)
        #expect(s.fields[1] == .keywordB)
        #expect(s.selections[0] == "a")
        #expect(s.selections[1] == nil)
        #expect(s.selections[2] == nil)
    }

    @Test func setSelectionClearsLowerSelections() {
        var s = BrowserPaneState()
        s.selections = ["a", "b", "c"]
        s.setSelection("X", at: 0)
        #expect(s.selections[0] == "X")
        #expect(s.selections[1] == nil)
        #expect(s.selections[2] == nil)
    }

    @Test func setSelectionAtMiddleClearsOnlyLower() {
        var s = BrowserPaneState()
        s.selections = ["a", "b", "c"]
        s.setSelection("Y", at: 1)
        #expect(s.selections[0] == "a")
        #expect(s.selections[1] == "Y")
        #expect(s.selections[2] == nil)
    }

    @Test func clearSelectionsResetsAllToNil() {
        var s = BrowserPaneState()
        s.selections = ["a", "b", "c"]
        s.clearSelections()
        #expect(s.selections == [nil, nil, nil])
    }

    @Test func setFieldNilDisablesColumn() {
        var s = BrowserPaneState()
        s.setField(nil, at: 1)
        #expect(s.fields[1] == nil)
    }

    @Test func codableRoundTrip() throws {
        var s = BrowserPaneState()
        s.fields = [.genre, .keywordB, .keywordC]
        s.selections = ["一般コミック", "tag-b", nil]
        s.height = 350
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(BrowserPaneState.self, from: data)
        #expect(decoded == s)
    }

    @Test func sqlColumnMapping() {
        #expect(BrowserPaneState.BrowseField.genre.sqlColumn == "genre")
        #expect(BrowserPaneState.BrowseField.series.sqlColumn == "series")
        #expect(BrowserPaneState.BrowseField.author.sqlColumn == "author")
        #expect(BrowserPaneState.BrowseField.neta.sqlColumn == "neta")
        #expect(BrowserPaneState.BrowseField.keywordA.sqlColumn == "keyword_a")
        #expect(BrowserPaneState.BrowseField.keywordB.sqlColumn == "keyword_b")
        #expect(BrowserPaneState.BrowseField.keywordC.sqlColumn == "keyword_c")
    }
}
