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

    final class Box { var persisted: [Int] = []; var opened: [Int] = [] }

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
}
