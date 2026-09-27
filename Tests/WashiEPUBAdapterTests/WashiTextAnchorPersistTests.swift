// SPDX-License-Identifier: MIT
import Testing
import WashiCore
import Washi
import EPUBAdapter
@testable import WashiEPUBAdapter

@Suite("G56-S2: 位置の報告へのアンカーの補完")
@MainActor
struct WashiTextAnchorPersistTests {
    /// 補完の返りを手で進めるための門。
    final class AnchorGate {
        var continuation: CheckedContinuation<EPUBLocator, Never>?
        func resume(_ l: EPUBLocator) { continuation?.resume(returning: l); continuation = nil }
    }

    private func makeHost(gate: AnchorGate) -> (WashiReaderHost, () -> [EPUBLocatorValue]) {
        let host = WashiReaderHost()
        var reports: [EPUBLocatorValue] = []
        host.onLocatorChange = { reports.append($0) }
        host.fetchAnchoredLocator = {
            await withCheckedContinuation { gate.continuation = $0 }
        }
        return (host, { reports })
    }

    /// 非同期の Task を 1 周回す。
    private func drain() async { for _ in 0..<5 { await Task.yield() } }

    @Test func reportsPlainThenAnchored() async {
        let gate = AnchorGate()
        let (host, reports) = makeHost(gate: gate)
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 3, progression: 0.4, idref: "c3"),
                        pageInItem: 2, pageCountInItem: 6)
        await drain()
        #expect(reports() == [EPUBLocatorValue(spine: 3, progress: 0.4, cfi: nil, engine: "washi")])
        // 補完は progress が少し違って返っても、報告の spine/progress を保つ
        gate.resume(EPUBLocator(spineIndex: 3, progression: 0.41, idref: "c3", textOffset: 900))
        await drain()
        #expect(reports().last == EPUBLocatorValue(spine: 3, progress: 0.4, cfi: "washi:t=900;idref=c3", engine: "washi"))
        #expect(host.locator == reports().last)
    }

    @Test func staleAnchorIsDropped() async {
        let gate = AnchorGate()
        let (host, reports) = makeHost(gate: gate)
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 3, progression: 0.4, idref: "c3"),
                        pageInItem: 2, pageCountInItem: 6)
        await drain()
        let first = gate.continuation
        gate.continuation = nil
        // 補完が返る前に次の報告
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 3, progression: 0.6, idref: "c3"),
                        pageInItem: 3, pageCountInItem: 6)
        await drain()
        first?.resume(returning: EPUBLocator(spineIndex: 3, progression: 0.4, idref: "c3", textOffset: 900))
        await drain()
        #expect(reports().allSatisfy { $0.cfi == nil })
        #expect(reports().last?.progress == 0.6)
    }

    @Test func anchorWithoutOffsetIsNotRepublished() async {
        let gate = AnchorGate()
        let (host, reports) = makeHost(gate: gate)
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 0, progression: 0), pageInItem: 0, pageCountInItem: 1)
        await drain()
        gate.resume(EPUBLocator(spineIndex: 0, progression: 0))   // 画像だけのページ等
        await drain()
        #expect(reports().count == 1)
    }

    @Test func restoredAnchorSurvivesLandingUntilMove() async {
        let gate = AnchorGate()
        let (host, reports) = makeHost(gate: gate)
        host.go(to: EPUBLocatorValue(spine: 5, progress: 0.3, cfi: "washi:t=77;idref=c5", engine: "washi"))
        // 着地の報告（アンカー無し）→ 復元アンカーを付けて出す
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 5, progression: 0.31, idref: "c5"),
                        pageInItem: 1, pageCountInItem: 4)
        #expect(reports().last?.cfi == "washi:t=77;idref=c5")
        // 同じ場所の再報告にも付く
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 5, progression: 0.31, idref: "c5"),
                        pageInItem: 1, pageCountInItem: 4)
        #expect(reports().last?.cfi == "washi:t=77;idref=c5")
        // 動いたら外れる
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 5, progression: 0.6, idref: "c5"),
                        pageInItem: 2, pageCountInItem: 4)
        #expect(reports().last?.cfi == nil)
        gate.continuation = nil
    }

    @Test func tearDownCancelsPendingAnchor() async {
        let gate = AnchorGate()
        let host = WashiReaderHost()
        var count = 0
        host.onLocatorChange = { _ in count += 1 }
        host.fetchAnchoredLocator = { await withCheckedContinuation { gate.continuation = $0 } }
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 1, progression: 0.2), pageInItem: 0, pageCountInItem: 2)
        await drain()
        host.tearDown()
        gate.resume(EPUBLocator(spineIndex: 1, progression: 0.2, textOffset: 5))
        await drain()
        #expect(count == 1)
    }
}
