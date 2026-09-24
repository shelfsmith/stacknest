// SPDX-License-Identifier: MIT
import AppKit
import Testing
import EPUBAdapter
@testable import WashiEPUBAdapter

/// G54-S3c: 巻送りで窓から外した reader は、コールバック・delegate・親ビューとの繋がりを全部断つ。
/// 容れ物を親から外すと Washi は `viewDidMoveToWindow(nil)` でネイティブキー監視を外す。
@Suite("G54-S3c: 窓から外した reader の後始末")
@MainActor
struct WashiTearDownTests {
    @Test func tearDownClearsCallbacksAndDetachesTheView() {
        let host = WashiReaderHost()
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        parent.addSubview(host.view)
        host.onLocatorChange = { _ in }
        host.onFontScaleChange = { _ in }
        host.onKeyEvent = { _ in true }
        host.onReachBookEdge = { _ in }
        host.onPageCensusChange = {}
        host.tearDown()
        #expect(host.onLocatorChange == nil)
        #expect(host.onFontScaleChange == nil)
        #expect(host.onKeyEvent == nil)
        #expect(host.onReachBookEdge == nil)
        #expect(host.onPageCensusChange == nil)
        #expect(host.reader.delegate == nil)
        #expect(host.view.superview == nil)
    }

    /// 読み込み前（窓に載る前）に外しても落ちず、2 回呼んでも落ちない。
    @Test func tearDownBeforeLoadIsSafeAndIdempotent() {
        let host = WashiReaderHost()
        host.tearDown()
        host.tearDown()
        #expect(host.view.superview == nil)
    }
}
