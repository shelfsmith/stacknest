// SPDX-License-Identifier: MIT
import AppKit
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

    // MARK: G56-S2 — Task 9 レビューの追補（controller Ruling 6）

    /// 控えた後に別の spine の報告が来たら（競合）、戻らずに控えを捨てる。
    @Test func otherSpineReportDropsTarget() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.fontScale = 1.4
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 4, progression: 0.1, idref: "c4"),
                        pageInItem: 0, pageCountInItem: 6)
        #expect(navs().isEmpty)
        // 控えは捨てられている: 後から元の spine の報告が来ても戻らない
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.47, idref: "c2"),
                        pageInItem: 5, pageCountInItem: 11)
        #expect(navs().isEmpty)
    }

    /// 同じ spine でも idref が両方あって食い違えば戻らない。
    @Test func idrefMismatchDropsTarget() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.fontScale = 1.4
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.47, idref: "other"),
                        pageInItem: 5, pageCountInItem: 11)
        #expect(navs().isEmpty)
    }

    /// 上限で adjustFontScale(by: +) しても Washi は変えない（報告も出ない）ので、控えない。
    @Test func adjustAtUpperLimitDoesNotCapture() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.reader.settings.fontScale = EPUBReaderView.fontScaleRange.upperBound
        host.adjustFontScale(by: 0.1)
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.6, idref: "c2"),
                        pageInItem: 4, pageCountInItem: 7)
        #expect(navs().isEmpty)
    }

    /// 範囲の内側なら adjustFontScale は控える（上の否定の対照）。
    @Test func adjustInsideRangeCaptures() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.adjustFontScale(by: 0.1)
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.47, idref: "c2"),
                        pageInItem: 5, pageCountInItem: 11)
        #expect(navs().count == 1)
    }

    /// 戻る報告と着地の報告は補完（JS 往復）を呼ばない。利用者が動いた後の報告は呼ぶ（対照）。
    @Test func relandingReportDoesNotFetch() async {
        final class Counter { var n = 0 }
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        let counter = Counter()
        host.fetchAnchoredLocator = { counter.n += 1; return EPUBLocator(spineIndex: 0) }
        host.fontScale = 1.4
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.47, idref: "c2"),
                        pageInItem: 5, pageCountInItem: 11)
        #expect(navs().count == 1)
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.5, idref: "c2"),
                        pageInItem: 5, pageCountInItem: 11)
        for _ in 0..<10 { await Task.yield() }
        #expect(counter.n == 0)
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.6, idref: "c2"),
                        pageInItem: 6, pageCountInItem: 11)
        for _ in 0..<10 { await Task.yield() }
        #expect(counter.n == 1)
    }

    /// tearDown は控えを消す。
    @Test func tearDownClearsTarget() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.fontScale = 1.4
        host.tearDown()
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.47, idref: "c2"),
                        pageInItem: 5, pageCountInItem: 11)
        #expect(navs().isEmpty)
    }

    // MARK: G56 最終レビューの修正

    /// 続けて変えたとき（着地の報告の前に 2 回目）も、同じ文へ戻る。
    @Test func rapidSecondChangeKeepsTheSentence() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.fontScale = 1.2
        // 1 回目の再ページ割り → 戻る（保護を張り直し、報告自体は保護の鍵が外れてアンカー無しで出る）
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.47, idref: "c2"),
                        pageInItem: 5, pageCountInItem: 11)
        #expect(navs().count == 1)
        // 着地の報告の前に 2 回目の変更
        host.fontScale = 1.4
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.44, idref: "c2"),
                        pageInItem: 6, pageCountInItem: 13)
        #expect(navs().count == 2)
        #expect(navs().map(\.textOffset) == [400, 400])
        #expect(navs().last?.idref == "c2")
    }

    /// 全画面で開く: 復元の保護が張られている（まだ動いていない）間の大きさの変化は、同じ文へ戻す。
    @Test func resizeWhileGuardedRelands() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.view.setFrameSize(NSSize(width: 800, height: 600))
        host.view.setFrameSize(NSSize(width: 1440, height: 900))
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.41, idref: "c2"),
                        pageInItem: 2, pageCountInItem: 5)
        #expect(navs().count == 1)
        #expect(navs().first?.textOffset == 400)
    }

    /// 同じ大きさ・0 の大きさでは控えない。
    @Test func unchangedOrZeroSizeDoesNotCapture() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.view.setFrameSize(NSSize(width: 800, height: 600))
        host.view.setFrameSize(NSSize(width: 800, height: 600))
        host.view.setFrameSize(.zero)
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.41, idref: "c2"),
                        pageInItem: 2, pageCountInItem: 5)
        #expect(navs().isEmpty)
    }

    /// 利用者が動いた後の大きさの変化（読書中のドラッグ）は対象外（spec §2.4）。
    @Test func resizeAfterUserMoveDoesNotReland() {
        for move in [0, 1, 2, 3, 4, 5, 6] {
            let clock = Clock()
            let (host, navs) = makeLoadedHost(clock: clock)
            host.view.setFrameSize(NSSize(width: 800, height: 600))
            switch move {
            case 0: host.goForward()
            case 1: host.goBackward()
            case 2: host.pageLeft()
            case 3: host.pageRight()
            case 4: host.goToBookStart()
            case 5: host.goToBookEnd()
            default: host.go(toGlobalPage: 3)
            }
            host.view.setFrameSize(NSSize(width: 1440, height: 900))
            host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.41, idref: "c2"),
                            pageInItem: 2, pageCountInItem: 5)
            #expect(navs().isEmpty, "move \(move)")
        }
    }

    /// 報告で保護が外れた（動いた）後の大きさの変化も対象外。
    @Test func resizeAfterReportedMoveDoesNotReland() {
        let clock = Clock()
        let (host, navs) = makeLoadedHost(clock: clock)
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.6, idref: "c2"),
                        pageInItem: 4, pageCountInItem: 7)
        host.view.setFrameSize(NSSize(width: 800, height: 600))
        host.view.setFrameSize(NSSize(width: 1440, height: 900))
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.55, idref: "c2"),
                        pageInItem: 2, pageCountInItem: 5)
        #expect(navs().isEmpty)
    }

    /// load 前の大きさの変化では控えない。
    @Test func resizeBeforeLoadDoesNotReland() {
        let host = WashiReaderHost()
        var navs: [EPUBLocator] = []
        host.navigateReader = { navs.append($0) }
        host.fetchAnchoredLocator = { EPUBLocator(spineIndex: 0) }
        host.go(to: EPUBLocatorValue(spine: 2, progress: 0.5, cfi: "washi:t=400;idref=c2", engine: "washi"))
        host.view.setFrameSize(NSSize(width: 800, height: 600))
        host.view.setFrameSize(NSSize(width: 1440, height: 900))
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 2, progression: 0.5, idref: "c2"),
                        pageInItem: 2, pageCountInItem: 5)
        #expect(navs.isEmpty)
    }
}
