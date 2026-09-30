// SPDX-License-Identifier: MIT
import AppKit
import CoreGraphics
import Testing
import AppCore
import LibraryStore
@testable import StackNest

/// G59: 画像ビューアのホイール／トラックパッドでのページ送り。
@MainActor
@Suite("G59: 画像ビューアのホイール送り", .serialized)
struct ViewerWheelPageTurnTests {
    private struct SolidPNGContent: BookContent {
        let count: Int
        var pageCount: Int { get async throws { count } }
        func imageData(at page: Int) async throws -> Data { Self.png }
        static let png: Data = {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return rep.representation(using: .png, properties: [:])!
        }()
    }

    private func make(direction: PageDirection = .rightToLeft,
                      wheel: Bool = true, horizontal: Bool = true, reversed: Bool = false)
        async -> ViewerWindowController {
        let c = ViewerWindowController(
            content: SolidPNGContent(count: 10), book: BookRow.g51Fixture(id: 1, title: "t"), pageCount: 10,
            options: ViewerOptions(pageDirection: direction, endOfBookBehavior: .stop),
            initialState: ResolvedViewerState(spreadEnabled: false, coverOffset: false, lastPage: 4, overrides: [:]),
            loadNextVolume: { _ in nil }, loadPrevVolume: { _ in nil },
            persistState: { _, _, _, _, _ in }, persistPageOverride: { _, _, _ in },
            suppressResumeDialog: true)
        c.pageTurnStyleProvider = { .off }
        c.wheelSettingsProvider = { (wheel, horizontal, reversed) }
        await waitUntil { !c.hasPendingDisplay }
        return c
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 精密なイベントを 16ms 間隔で 10 個(1 ジェスチャ)
    private func swipe(_ c: ViewerWindowController, dx: Double = 0, dy: Double = 0, start: TimeInterval) {
        for i in 0..<10 {
            c.handleWheelPageTurn(deltaX: dx, deltaY: dy, hasPreciseDeltas: true,
                                  timestamp: start + Double(i) * 0.016)
        }
    }

    @Test func verticalWheelTurnsForwardAndBackward() async {
        let c = await make()
        #expect(c.currentPageForTesting == 4)
        swipe(c, dy: -12, start: 100)
        await waitUntil { !c.hasPendingDisplay }
        #expect(c.currentPageForTesting == 5)
        swipe(c, dy: 12, start: 101)
        await waitUntil { !c.hasPendingDisplay }
        #expect(c.currentPageForTesting == 4)
        c.close()
    }

    @Test func horizontalFollowsPageDirectionAndReverse() async {
        let rtl = await make(direction: .rightToLeft)
        swipe(rtl, dx: 12, start: 100)          // 左へ = 右綴じでは次
        await waitUntil { !rtl.hasPendingDisplay }
        #expect(rtl.currentPageForTesting == 5)
        rtl.close()

        let ltr = await make(direction: .leftToRight)
        swipe(ltr, dx: 12, start: 100)          // 左へ = 左綴じでは前
        await waitUntil { !ltr.hasPendingDisplay }
        #expect(ltr.currentPageForTesting == 3)
        ltr.close()

        let reversed = await make(direction: .rightToLeft, reversed: true)
        swipe(reversed, dx: 12, start: 100)     // 反転: 左へ → 右へ = 右綴じでは前
        await waitUntil { !reversed.hasPendingDisplay }
        #expect(reversed.currentPageForTesting == 3)
        reversed.close()
    }

    @Test func settingsTurnWheelPagingOff() async {
        let off = await make(wheel: false)
        swipe(off, dy: -12, start: 100)
        swipe(off, dx: 12, start: 101)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(off.currentPageForTesting == 4, "「スクロールでページを送る」OFF なら縦横とも送らない")
        off.close()

        let noHorizontal = await make(horizontal: false)
        swipe(noHorizontal, dx: 12, start: 100)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(noHorizontal.currentPageForTesting == 4, "横方向 OFF なら横では送らない")
        swipe(noHorizontal, dy: -12, start: 101)
        await waitUntil { !noHorizontal.hasPendingDisplay }
        #expect(noHorizontal.currentPageForTesting == 5, "縦では送る")
        noHorizontal.close()
    }

    // MARK: キャンバス — フィット表示・ルーペ OFF のときだけ送りに回す

    private func scrollEvent(dy: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                         wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return NSEvent(cgEvent: cg)!
    }

    @Test func canvasForwardsOnlyAtFitWithLoupeOff() {
        let canvas = ViewerCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var forwarded = 0
        canvas.onWheelPageTurn = { _ in forwarded += 1 }

        canvas.scrollWheel(with: scrollEvent(dy: -12))
        #expect(forwarded == 1, "フィット表示・ルーペ OFF なら送りに回す")

        canvas.loupeEnabled = true
        canvas.scrollWheel(with: scrollEvent(dy: -12))
        #expect(forwarded == 1, "ルーペ ON のときは倍率に使う")
        canvas.loupeEnabled = false

        canvas.zoomIn()
        canvas.scrollWheel(with: scrollEvent(dy: -12))
        #expect(forwarded == 1, "拡大中はパンに使う")
    }
}
