// SPDX-License-Identifier: MIT
import Testing
@testable import LibraryStore

@Suite("FilterState replaceSelection")
struct FilterStateReplaceSelectionTests {

    @Test
    func replaceSelectionOverwritesGenrePreservesOthers() {
        var state = FilterState()
        state.replaceSelection(for: "genre",  with: ["旧ジャンル"])
        state.replaceSelection(for: "author", with: ["著者A"])
        // 上書き
        state.replaceSelection(for: "genre", with: ["新ジャンル"])
        #expect(state.genres  == ["新ジャンル"])
        #expect(state.authors == ["著者A"])   // 他 field は維持
    }

    @Test
    func replaceSelectionWithEmptySetClearsField() {
        var state = FilterState()
        state.replaceSelection(for: "genre", with: ["A", "B"])
        state.replaceSelection(for: "genre", with: [])
        #expect(state.genres.isEmpty)
    }

    @Test
    func replaceSelectionSeries() {
        var state = FilterState()
        state.replaceSelection(for: "series", with: ["シリーズX"])
        #expect(state.serieses == ["シリーズX"])
    }

    @Test
    func replaceSelectionAuthor() {
        var state = FilterState()
        state.replaceSelection(for: "author", with: ["作者Z"])
        #expect(state.authors == ["作者Z"])
    }

    @Test
    func replaceSelectionNeta() {
        var state = FilterState()
        state.replaceSelection(for: "neta", with: ["ネタA"])
        #expect(state.netas == ["ネタA"])
    }

    @Test
    func replaceSelectionKeywordA() {
        var state = FilterState()
        state.replaceSelection(for: "keywordA", with: ["KW1"])
        #expect(state.keywordAs == ["KW1"])
    }

    @Test
    func replaceSelectionKeywordB() {
        var state = FilterState()
        state.replaceSelection(for: "keywordB", with: ["KW2"])
        #expect(state.keywordBs == ["KW2"])
    }

    @Test
    func replaceSelectionKeywordC() {
        var state = FilterState()
        state.replaceSelection(for: "keywordC", with: ["KW3"])
        #expect(state.keywordCs == ["KW3"])
    }

    @Test
    func replaceSelectionUnknownFieldIsNoop() {
        var state = FilterState()
        let before = state
        state.replaceSelection(for: "unknown_xyz", with: ["ignored"])
        #expect(state == before)
    }
}
