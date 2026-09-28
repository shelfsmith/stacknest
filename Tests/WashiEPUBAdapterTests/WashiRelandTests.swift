// SPDX-License-Identifier: MIT
import Foundation
import Testing
import WashiCore
import Washi
import EPUBAdapter
@testable import WashiEPUBAdapter

@Suite("G56-S2: 設定変更の後に同じ文へ戻る")
@MainActor
struct WashiRelandTests {
    private final class Clock { var t = Date(timeIntervalSince1970: 1000) }

    /// 初回 load 済みの状態を作り、アンカー付きの位置を lastPublished に載せる。
    private func makeLoadedHost(clock: Clock) -> (WashiReaderHost, () -> [EPUBLocator]) {
        let host = WashiReaderHost()
        var navigations: [EPUBLocator] = []
        host.navigateReader = { navigations.append($0) }
        host.now = { clock.t }
        host.fetchAnchoredLocator = { EPUBLocator(spineIndex: 0) }   // 補完は付けない（テストは復元の保護で載せる）
        host.markLoadedForTesting()
        host.go(to: EPUBLocatorValue(spine: 2, progress: 0.5, cfi: "washi:t=400;idref=c2", engine: "washi"))
        navigations.removeAll()
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.5, idref: "c2"),
                        pageInItem: 3, pageCountInItem: 7)
        return (host, { navigations })
    }

    @Test func fontScaleChangeRelandsOnNextReport() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.fontScale = 1.4
        // 再ページ割りの報告（進行率で組み直した位置）
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.47, idref: "c2"),
                        pageInItem: 5, pageCountInItem: 11)
        #expect(navs().count == 1)
        #expect(navs().first?.textOffset == 400)
        #expect(navs().first?.idref == "c2")
        // 着地の報告の後はもう戻さない
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.5, idref: "c2"),
                        pageInItem: 5, pageCountInItem: 11)
        #expect(navs().count == 1)
    }

    @Test func sameValueDoesNotCapture() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.fontScale = host.fontScale
        host.columnMode = host.columnMode
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.6, idref: "c2"),
                        pageInItem: 4, pageCountInItem: 7)
        #expect(navs().isEmpty)
    }

    @Test func columnModeAndResetAndPinchCapture() {
        for change in [0, 1, 2] {
            let clock = Clock()
            let (host, navs) = makeLoadedHost(clock: clock)
            switch change {
            case 0: host.columnMode = .double
            case 1: host.reader.settings.fontScale = 1.3; host.resetFontScale()
            default: host.readerView(host.reader, didChangeFontScale: 1.2)
            }
            host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.45, idref: "c2"),
                            pageInItem: 2, pageCountInItem: 5)
            #expect(navs().count == 1, "change \(change)")
        }
    }

    @Test func userMoveCancels() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.fontScale = 1.4
        host.goForward()
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.6, idref: "c2"),
                        pageInItem: 6, pageCountInItem: 11)
        #expect(navs().isEmpty)
    }

    @Test func expiredTargetIsDropped() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.fontScale = 1.4
        clock.t = clock.t.addingTimeInterval(WashiReaderHost.relandDeadline + 0.1)
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.6, idref: "c2"),
                        pageInItem: 6, pageCountInItem: 11)
        #expect(navs().isEmpty)
    }

    @Test func noAnchorNoReland() {
        let host = WashiReaderHost()
        var navs: [EPUBLocator] = []
        host.navigateReader = { navs.append($0) }
        host.fetchAnchoredLocator = { EPUBLocator(spineIndex: 0) }
        host.markLoadedForTesting()
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 1, progression: 0.2), pageInItem: 0, pageCountInItem: 3)
        host.fontScale = 1.4
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 1, progression: 0.25), pageInItem: 1, pageCountInItem: 5)
        #expect(navs.isEmpty)
    }

    @Test func beforeLoadNoCapture() {
        let host = WashiReaderHost()
        var navs: [EPUBLocator] = []
        host.navigateReader = { navs.append($0) }
        host.fontScale = 1.4   // 窓が復元値を当てる経路（load 前）
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 0, progression: 0), pageInItem: 0, pageCountInItem: 1)
        #expect(navs.isEmpty)
    }
}
