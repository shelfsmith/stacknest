// SPDX-License-Identifier: MIT
import AppKit
import Testing
import AppCore
import EPUBAdapter
import LibraryStore
@testable import StackNest

/// G51（Q4）: 自動送りと巻送り。テキスト EPUB 以外の巻は閉じてから兄弟を注入された経路で開く（テキスト EPUB の差し替えは `EPUBReaderWindowSwapTests`）。
@MainActor
@Suite("G51: EPUB 窓の自動送りと巻送り")
struct EPUBReaderWindowVolumeTests {
    private func make() -> (EPUBReaderWindowController, FakeEPUBReader) {
        let reader = FakeEPUBReader()
        let book = BookRow.g51Fixture(id: 1, title: "t")
        let c = EPUBReaderWindowController(book: book, reader: reader, persist: { _ in })
        c.bindings = .defaults
        return (c, reader)
    }

    @Test func nextVolumeOpensSiblingThroughInjectedPath() async throws {
        let (c, _) = make()
        let sibling = BookRow.g51Fixture(id: 2, title: "t2")
        var opened: [Int] = []
        c.resolveSibling = { cur, dir in
            #expect(cur.id == 1); #expect(dir == .next)
            return .reopen(sibling)
        }
        c.openSibling = { opened.append($0.id) }
        c.perform(.nextVolume)
        try await Task.sleep(for: .milliseconds(50))
        #expect(opened == [2])
    }

    @Test func missingSiblingShowsNote() async throws {
        let (c, _) = make()
        c.resolveSibling = { _, _ in .noSibling }
        c.openSibling = { _ in Issue.record("開いてはいけない") }
        c.perform(.prevVolume)
        try await Task.sleep(for: .milliseconds(50))
        #expect(c.lastHUDNote == "前の巻なし")
    }

    @Test func withoutInjectionShowsNote() {
        let (c, _) = make()
        c.perform(.nextVolume)
        #expect(c.lastHUDNote == "次の巻なし")
    }

    @Test func autoAdvanceStopsOnManualAction() {
        let (c, r) = make()
        c.perform(.toggleAutoAdvance)
        #expect(c.lastHUDNote?.hasPrefix("スライドショー ▶") == true)
        c.perform(.nextPage)                         // 手動操作で解除
        #expect(r.calls == ["goForward"])
        c.perform(.toggleAutoAdvance)                // 解除済みなので「開始」になる
        #expect(c.lastHUDNote?.hasPrefix("スライドショー ▶") == true)
        c.perform(.toggleAutoAdvance)
        #expect(c.lastHUDNote == "スライドショー 停止")
    }

    @Test func bookEndDuringAutoAdvanceFollowsSetting() {
        let (c, r) = make()
        let ud = ViewerSettings.shared.endOfBookBehavior
        defer { ViewerSettings.shared.endOfBookBehavior = ud }
        ViewerSettings.shared.endOfBookBehavior = .loop
        c.perform(.toggleAutoAdvance)
        r.onReachBookEdge?(true)
        #expect(r.calls.last == "goToBookStart")
        ViewerSettings.shared.endOfBookBehavior = .stop
        r.onReachBookEdge?(true)
        #expect(c.lastHUDNote == "最終ページです")
        r.onReachBookEdge?(false)                    // 先頭側は何もしない
        #expect(c.lastHUDNote == "最終ページです")
    }

    /// I3: 自動送りが動いていない（＝手動でページ送りして末尾に達した）ときも `endOfBookBehavior` に従う
    /// （画像ビューアと同じパリティ。以前は自動送り中でなければ無視していた）。
    @Test func manualTurnAtBookEndFollowsSettingWithoutAutoAdvance() {
        let (c, r) = make()
        let ud = ViewerSettings.shared.endOfBookBehavior
        defer { ViewerSettings.shared.endOfBookBehavior = ud }
        ViewerSettings.shared.endOfBookBehavior = .loop
        r.onReachBookEdge?(true)                      // 自動送りは起動していない
        #expect(r.calls.last == "goToBookStart")
    }
}
