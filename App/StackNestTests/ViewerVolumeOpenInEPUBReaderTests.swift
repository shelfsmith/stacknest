// SPDX-License-Identifier: MIT
import AppKit
import Testing
import AppCore
import EPUBAdapter
import LibraryStore
@testable import StackNest

/// G54-S3c（spec §4.3）: 画像ビューアの巻送りで次の巻がテキスト EPUB なら、差し替えずに窓を閉じ、
/// 所有者の通常の経路で EPUB の窓を開く（以前は 0 ページで「次の巻を開けません」になって止まっていた）。
@MainActor
@Suite("G54-S3c: 画像ビューア → テキスト EPUB", .serialized)
struct ViewerVolumeOpenInEPUBReaderTests {
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

    final class Box { var persisted: [Int] = []; var opened: [Int] = []; var closed = false; var resolves = 0 }
    final class Gate { var open = false }

    private func make(next: VolumeLoad?) async -> (ViewerWindowController, Box) {
        let box = Box()
        let c = ViewerWindowController(
            content: SolidPNGContent(count: 3), book: .g51Fixture(id: 1, title: "t"), pageCount: 3,
            options: ViewerOptions(pageDirection: .leftToRight, endOfBookBehavior: .stop),
            initialState: ResolvedViewerState(spreadEnabled: false, coverOffset: false, lastPage: 0, overrides: [:]),
            loadNextVolume: { _ in next }, loadPrevVolume: { _ in nil },
            persistState: { b, _, _, _, _ in box.persisted.append(b.id) },
            persistPageOverride: { _, _, _ in },
            suppressResumeDialog: true)
        await waitUntil { !c.hasPendingDisplay }
        return (c, box)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func textEPUBSiblingIsHandedToTheOwner() async {
        let (c, box) = await make(next: .openInEPUBReader(.g51Fixture(id: 2, title: "t2")))
        c.onOpenInEPUBReader = { box.opened.append($0.id) }
        let before = box.persisted.count
        c.perform(.nextVolume)
        await waitUntil { box.opened == [2] }
        #expect(box.opened == [2])
        // 旧巻の保存は loadVolume 冒頭の 1 回だけ（閉じるときに送り直さない＝リモートで 2 回 POST しない）
        #expect(box.persisted.count - before == 1)
        #expect(c.lastHUDNote != "次の巻を開けません（0ページ）")
    }

    @Test func withoutTheOwnerHookItStaysAndSaysSo() async {
        let (c, box) = await make(next: .openInEPUBReader(.g51Fixture(id: 2, title: "t2")))
        c.perform(.nextVolume)
        await waitUntil { c.lastHUDNote != nil }
        #expect(c.lastHUDNote == "この巻はここでは開けません")
        #expect(box.opened.isEmpty)
    }

    @Test func missingVolumeStillShowsTheUsualNote() async {
        let (c, _) = await make(next: nil)
        c.perform(.nextVolume)
        await waitUntil { c.lastHUDNote != nil }
        #expect(c.lastHUDNote == "次の巻なし")
    }

    /// G54-S3cd 最終レビュー Important #1: 解決中（await resolve）にユーザーが窓を閉じたら、
    /// 遅れて届いた結果は捨てる。`EPUBReaderWindowSwapTests.closingWhileResolvingDiscardsTheResult` に倣う。
    @Test func closingWhileResolvingDiscardsTheResult() async {
        let box = Box()
        let gate = Gate()
        let c = ViewerWindowController(
            content: SolidPNGContent(count: 3), book: .g51Fixture(id: 1, title: "t"), pageCount: 3,
            options: ViewerOptions(pageDirection: .leftToRight, endOfBookBehavior: .stop),
            initialState: ResolvedViewerState(spreadEnabled: false, coverOffset: false, lastPage: 0, overrides: [:]),
            loadNextVolume: { _ in
                while !gate.open { try? await Task.sleep(for: .milliseconds(5)) }
                return .openInEPUBReader(.g51Fixture(id: 2, title: "t2"))
            },
            loadPrevVolume: { _ in nil },
            persistState: { b, _, _, _, _ in box.persisted.append(b.id) },
            persistPageOverride: { _, _, _ in },
            suppressResumeDialog: true)
        await waitUntil { !c.hasPendingDisplay }
        c.onOpenInEPUBReader = { box.opened.append($0.id) }
        c.perform(.nextVolume)
        c.window?.close()
        gate.open = true
        // 結果が届いてもなお opened が空のままであることを、十分な時間待って確かめる。
        try? await Task.sleep(for: .milliseconds(200))
        #expect(box.opened.isEmpty)
    }

    /// G54-S3e（spec §2.1-1）: 所有者が「次の巻は開けない」と判断したら、窓は閉じずに留まり、文言を HUD に出す。
    /// 以前は留まる手段が `nil`（＝「次の巻なし」という誤った文言）しか無かった。
    @Test func unavailableStaysOpenAndShowsTheNote() async {
        let (c, box) = await make(next: .unavailable(note: "次の巻を開けません（ファイルが見つかりません）"))
        c.onOpenInEPUBReader = { box.opened.append($0.id) }
        c.onClose = { box.closed = true }
        c.perform(.nextVolume)
        await waitUntil { c.lastHUDNote != nil }
        #expect(c.lastHUDNote == "次の巻を開けません（ファイルが見つかりません）")
        #expect(box.opened.isEmpty)
        #expect(!box.closed)
        c.window?.close()
    }

    /// G54-S3e: 文言が無い（錠の失効など、所有者が書庫側で別途知らせる）ときは何も出さない。
    /// Review Focus 2: 留まった後も、次の巻送りでもう一度解決に行く（`isSwapping` が戻っている）。
    @Test func unavailableWithoutNoteIsSilentAndTheNextPressResolvesAgain() async {
        let box = Box()
        let c = ViewerWindowController(
            content: SolidPNGContent(count: 3), book: .g51Fixture(id: 1, title: "t"), pageCount: 3,
            options: ViewerOptions(pageDirection: .leftToRight, endOfBookBehavior: .stop),
            initialState: ResolvedViewerState(spreadEnabled: false, coverOffset: false, lastPage: 0, overrides: [:]),
            loadNextVolume: { _ in
                box.resolves += 1
                return .unavailable(note: nil)
            },
            loadPrevVolume: { _ in nil },
            persistState: { b, _, _, _, _ in box.persisted.append(b.id) },
            persistPageOverride: { _, _, _ in },
            suppressResumeDialog: true)
        await waitUntil { !c.hasPendingDisplay }
        c.onClose = { box.closed = true }
        c.perform(.nextVolume)
        await waitUntil { box.resolves == 1 }
        // 結果の処理（MainActor の Task の続き）が終わるのを待つ。
        try? await Task.sleep(for: .milliseconds(100))
        #expect(c.lastHUDNote == nil)
        #expect(!box.closed)
        c.perform(.nextVolume)
        await waitUntil { box.resolves == 2 }
        #expect(box.resolves == 2)
        c.window?.close()
    }
}
