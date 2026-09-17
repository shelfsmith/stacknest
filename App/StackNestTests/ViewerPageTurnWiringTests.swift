// SPDX-License-Identifier: MIT
import AppKit
import Testing
import AppCore
import EPUBAdapter
import LibraryStore
@testable import StackNest

/// G54-S3: 画像ビューアの演出は**隣への送りだけ**に掛かり、送れなかったときは外す（spec §4.2）。
@MainActor
@Suite("G54-S3: 画像ビューアのページ送りの演出の配線", .serialized)
struct ViewerPageTurnWiringTests {
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

    @MainActor
    private final class RecordingAnimator: PageTurnAnimating {
        var calls: [String] = []
        func capture(from view: NSView) -> Bool { calls.append("capture"); return true }
        func run(_ plan: PageTurnPlan) { calls.append("run(\(plan.style.rawValue),\(plan.slideTowardRight))") }
        func cancel() { calls.append("cancel") }
    }

    private final class Clock { var t = Date(timeIntervalSince1970: 1_000) }

    private func make(pages: Int = 5, style: PageTurnStyleValue = .slide)
        async -> (ViewerWindowController, RecordingAnimator, Clock) {
        let book = BookRow.g51Fixture(id: 1, title: "t")
        let c = ViewerWindowController(
            content: SolidPNGContent(count: pages), book: book, pageCount: pages,
            options: ViewerOptions(pageDirection: .rightToLeft, endOfBookBehavior: .stop),
            initialState: ResolvedViewerState(spreadEnabled: false, coverOffset: false, lastPage: 0, overrides: [:]),
            loadNextVolume: { _ in nil }, loadPrevVolume: { _ in nil },
            persistState: { _, _, _, _, _ in }, persistPageOverride: { _, _, _ in },
            suppressResumeDialog: true)
        let animator = RecordingAnimator()
        let clock = Clock()
        c.pageTurnAnimator = animator
        c.pageTurnStyleProvider = { style }
        c.reduceMotionProvider = { false }
        c.now = { clock.t }
        await waitUntil { !c.hasPendingDisplay }
        return (c, animator, clock)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func nextPageCapturesThenRunsAfterTheNewPageIsDrawn() async {
        let (c, a, _) = await make()
        c.perform(.nextPage)
        await waitUntil { a.calls.contains { $0.hasPrefix("run") } }
        #expect(a.calls == ["cancel", "capture", "run(slide,true)"])
        c.close()
    }

    @Test func offStyleNeverCaptures() async {
        let (c, a, _) = await make(style: .off)
        c.perform(.nextPage)
        await waitUntil { !c.hasPendingDisplay }
        #expect(!a.calls.contains("capture"))
        #expect(!a.calls.contains { $0.hasPrefix("run") })
        // G54-S3 fix round 1 (Minor B): 演出が無いこと「だけ」ではなく、送り自体は起きたことも確かめる
        // （perform が丸ごと no-op でも上の #expect は素通りしてしまうため）。
        #expect(c.currentPageForTesting == 1)
        c.close()
    }

    @Test func rapidSecondTurnIsNotCaptured() async {
        let (c, a, _) = await make()
        c.perform(.nextPage)
        await waitUntil { !c.hasPendingDisplay && a.calls.contains { $0.hasPrefix("run") } }
        c.perform(.nextPage)                         // 時計を進めない＝経過 0 秒
        await waitUntil { !c.hasPendingDisplay }
        #expect(a.calls.filter { $0 == "capture" }.count == 1)
        // G54-S3 fix round 1 (Minor B): 2 回とも実際に送れたことを確認する。
        #expect(c.currentPageForTesting == 2)
        c.close()
    }

    @Test func jumpsNeverCapture() async {
        let (c, a, _) = await make()   // pages: 5（既定）
        c.perform(.jumpToPercent50)
        await waitUntil { !c.hasPendingDisplay }
        // G54-S3 fix round 1 (Minor B): ジャンプ自体は起きたことを確認する。
        #expect(c.currentPageForTesting != 0)
        c.perform(.lastPage)
        await waitUntil { !c.hasPendingDisplay }
        #expect(!a.calls.contains("capture"))
        #expect(c.currentPageForTesting == 4)   // pageCount(5) - 1
        c.close()
    }

    @Test func stoppingAtTheLastPageCancelsWithoutRunning() async {
        let (c, a, _) = await make(pages: 1)
        c.perform(.nextPage)                         // 1 ページの本: advance は endStop
        #expect(a.calls == ["cancel", "capture", "cancel"])
        c.close()
    }

    @Test func previousAtTheFirstPageCancelsWithoutRunning() async {
        let (c, a, _) = await make()
        c.perform(.previousPage)                     // 先頭で戻る: 位置が変わらない
        await waitUntil { !c.hasPendingDisplay }
        #expect(a.calls == ["cancel", "capture", "cancel"])
        c.close()
    }

    // G54-S3 final review fix (Important #1): スライドショーの自動送りも goNext() と同じ配線で
    // 演出を掛けること（autoAdvanceTick() が model.advance()/loadCurrentPage() を直呼びして
    // preparePageTurn/armPageTurn/cancelPageTurn を素通りしていた欠陥の回帰テスト）。
    @Test func slideshowTickAnimatesLikeGoNext() async {
        let (c, a, clock) = await make()
        clock.t = clock.t.addingTimeInterval(1)
        c.autoAdvanceTick()
        await waitUntil { a.calls.contains { $0.hasPrefix("run") } }
        #expect(a.calls == ["cancel", "capture", "run(slide,true)"])
        #expect(c.currentPageForTesting == 1)
        c.close()
    }

    @Test func slideshowTickAtTheLastPageCancelsWithoutRunning() async {
        let (c, a, clock) = await make(pages: 1)
        clock.t = clock.t.addingTimeInterval(1)
        c.autoAdvanceTick()                          // 1 ページの本: advance は endStop
        #expect(a.calls == ["cancel", "capture", "cancel"])
        c.close()
    }
}
