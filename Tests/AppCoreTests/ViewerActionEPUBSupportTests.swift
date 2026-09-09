// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("G51: EPUB が扱う ViewerAction の集合")
struct ViewerActionEPUBSupportTests {
    @Test func includesNavigationZoomSpreadVolumeMisc() {
        let s = ViewerAction.epubSupported
        for a: ViewerAction in [.nextPage, .previousPage, .pageLeftward, .pageRightward, .firstPage, .lastPage,
                                .jumpToPercent0, .jumpToPercent50, .jumpToPercent90,
                                .zoomIn, .zoomOut, .fitToWindow,
                                .toggleSpread, .toggleAutoAdvance, .nextVolume, .prevVolume,
                                .toggleFullScreen, .close, .showHelp] {
            #expect(s.contains(a), "\(a) は EPUB で扱う")
        }
    }
    @Test func excludesImageOnlyActions() {
        let s = ViewerAction.epubSupported
        for a: ViewerAction in [.toggleLoupe, .toggleCoverOffset, .cyclePageLayout, .cycleEndOfBookBehavior,
                                .togglePageDirection, .skipForward, .skipBackward] {
            #expect(!s.contains(a), "\(a) は EPUB で扱わない")
        }
    }
    @Test func groupedHelpCanBeFiltered() {
        let all = ViewerHelpRows.makeGrouped(from: .defaults)
        let epub = ViewerHelpRows.makeGrouped(from: .defaults, including: ViewerAction.epubSupported)
        let allRows = all.flatMap(\.rows).count
        let epubRows = epub.flatMap(\.rows).count
        #expect(epubRows == ViewerAction.epubSupported.count)
        #expect(epubRows < allRows)
        // ルーペの行は消え、空になったセクションは残さない
        #expect(!epub.flatMap(\.rows).contains { $0.action == ViewerAction.toggleLoupe.displayName })
        #expect(epub.allSatisfy { !$0.rows.isEmpty })
    }
    @Test func groupedHelpWithoutFilterIsUnchanged() {
        let a = ViewerHelpRows.makeGrouped(from: .defaults)
        let b = ViewerHelpRows.makeGrouped(from: .defaults, including: nil)
        #expect(a.map(\.section) == b.map(\.section))
        #expect(a.flatMap(\.rows).map(\.action) == b.flatMap(\.rows).map(\.action))
    }
}
