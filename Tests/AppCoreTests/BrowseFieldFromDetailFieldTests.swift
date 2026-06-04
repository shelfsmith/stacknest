// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

// NOTE: DetailField lives in App/StackNest (Xcode target), which cannot be imported here.
// We test BrowserPaneState.BrowseField.init?(fieldName:) — the String-key bridge that
// BrowseField.init?(from: DetailField) delegates to. All mapping logic lives in AppCore,
// so these tests provide equivalent coverage.

private typealias BrowseField = BrowserPaneState.BrowseField

@Suite("BrowseField from fieldName (DetailField mapping coverage)")
struct BrowseFieldFromDetailFieldTests {
    @Test func genreMaps()    { #expect(BrowseField(fieldName: "genre")    == .genre) }
    @Test func seriesMaps()   { #expect(BrowseField(fieldName: "series")   == .series) }
    @Test func authorMaps()   { #expect(BrowseField(fieldName: "author")   == .author) }
    @Test func keywordAMaps() { #expect(BrowseField(fieldName: "keywordA") == .keywordA) }
    @Test func keywordBMaps() { #expect(BrowseField(fieldName: "keywordB") == .keywordB) }
    @Test func keywordCMaps() { #expect(BrowseField(fieldName: "keywordC") == .keywordC) }
    @Test func netaMaps()     { #expect(BrowseField(fieldName: "neta")     == .neta) }
    @Test func titleReturnsNil()  { #expect(BrowseField(fieldName: "title")  == nil) }
    @Test func volumeReturnsNil() { #expect(BrowseField(fieldName: "volume") == nil) }
    @Test func memoReturnsNil()   { #expect(BrowseField(fieldName: "memo")   == nil) }
    @Test func unknownReturnsNil() { #expect(BrowseField(fieldName: "unknown_xyz") == nil) }
}
