// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@Suite("RemoteBrowseState 永続化・進捗解決")
struct RemoteBrowseStatePersistenceTests {
    private func sample() -> RemoteBrowseState {
        var pane = BrowserPaneState()
        pane.selections = ["少年", nil, "SF"]
        var filter = FilterState()
        filter.replaceSelection(for: "genre", with: ["一般コミック"])
        return RemoteBrowseState(browserPaneState: pane, sortKey: "series", ascending: false,
                                 isGrid: true, filterState: filter, sidebar: .shelf(42))
    }

    @Test func browseStateCodableRoundTrip() throws {
        let s = sample()
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(RemoteBrowseState.self, from: data)
        #expect(back == s)
    }

    @Test func sidebarSelectionCodableRoundTrip() throws {
        let cases: [RemoteSidebarSelection] = [.library, .favorites(1), .recent, .shelf(7), .smartShelf(9)]
        for c in cases {
            let data = try JSONEncoder().encode(c)
            #expect(try JSONDecoder().decode(RemoteSidebarSelection.self, from: data) == c)
        }
    }

    @Test func prefsSaveLoadIsPerLibrary() {
        let suite = UserDefaults(suiteName: "test.remote.browsestate.\(UUID().uuidString)")!
        let prefs = RemoteBrowsePreferences(defaults: suite)
        let sid1 = UUID(); let sid2 = UUID()
        let s = sample()
        prefs.setBrowseState(s, serverID: sid1, libraryUUID: "libA")
        // 同一キーは読める
        #expect(prefs.browseState(serverID: sid1, libraryUUID: "libA") == s)
        // 別 serverID / 別 libraryUUID は混ざらない
        #expect(prefs.browseState(serverID: sid2, libraryUUID: "libA") == nil)
        #expect(prefs.browseState(serverID: sid1, libraryUUID: "libB") == nil)
    }

    @Test func resolveResumePagePicksMax() {
        #expect(resolveResumePage(server: 5, offline: 8) == 8)
        #expect(resolveResumePage(server: 10, offline: 3) == 10)
        #expect(resolveResumePage(server: nil, offline: nil) == 0)
        #expect(resolveResumePage(server: 4, offline: nil) == 4)
        #expect(resolveResumePage(server: nil, offline: 6) == 6)
    }
}
