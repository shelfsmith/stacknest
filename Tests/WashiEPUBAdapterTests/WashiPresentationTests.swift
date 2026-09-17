// SPDX-License-Identifier: MIT
import Testing
import EPUBAdapter
import Washi
@testable import WashiEPUBAdapter

@Suite("G54-S3: 演出・ノンブル・census 通知の Washi 写像")
@MainActor
struct WashiPresentationTests {
    @Test func pageTurnStyleMapsBothWays() {
        let host = WashiReaderHost()
        host.pageTurnStyle = .off
        #expect(host.reader.settings.pageTurnStyle == .none)
        #expect(host.pageTurnStyle == .off)
        host.pageTurnStyle = .fade
        #expect(host.reader.settings.pageTurnStyle == .fade)
        #expect(host.pageTurnStyle == .fade)
        host.pageTurnStyle = .slide
        #expect(host.reader.settings.pageTurnStyle == .slide)
        #expect(host.pageTurnStyle == .slide)
    }

    @Test func showsFolioMapsToPageFurniture() {
        let host = WashiReaderHost()
        host.showsFolio = false
        #expect(host.reader.settings.showsPageFurniture == false)
        host.showsFolio = true
        #expect(host.reader.settings.showsPageFurniture == true)
        #expect(host.showsFolio == true)
    }

    @Test func censusUpdateIsForwarded() {
        let host = WashiReaderHost()
        var count = 0
        host.onPageCensusChange = { count += 1 }
        host.readerViewDidUpdatePageCensus(host.reader)
        #expect(count == 1)
    }

    @Test func directionAndRangeBeforeLoad() {
        let host = WashiReaderHost()
        #expect(host.isRightToLeft == false)
        #expect(host.currentGlobalPageRange == nil)
    }
}
