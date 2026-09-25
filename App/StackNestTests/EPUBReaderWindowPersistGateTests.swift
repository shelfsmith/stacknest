// SPDX-License-Identifier: MIT
import AppKit
import Testing
import AppCore
import EPUBAdapter
import LibraryStore
@testable import StackNest

/// G54-S3e（spec §2.1-8）: manifest なしで開いた本（`holdsPersistUntilMoved`）は、reader が最初に報告した位置と
/// 違う位置が来るまで保存しない。門は reader の**報告ごとに**見る（保存は 0.4 秒のデバウンス後なので、
/// 保存の呼び出しだけを見ると、開いてすぐ送った最初の移動を「最初の位置」と取り違える）。
@MainActor
@Suite("G54-S3e: 利用者が動くまで保存しない（EPUB の窓）", .serialized)
struct EPUBReaderWindowPersistGateTests {
    final class Box { var persisted: [EPUBLocatorValue] = [] }

    private func freshSettings() -> ViewerSettings {
        let name = "g54s3e-epub-gate-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        return ViewerSettings(defaults: ud)
    }

    private func loc(_ spine: Int, _ progress: Double) -> EPUBLocatorValue {
        EPUBLocatorValue(spine: spine, progress: progress, cfi: nil, engine: nil)
    }

    private func make(holds: Bool) -> (EPUBReaderWindowController, FakeEPUBReader, Box, Int) {
        let reader = FakeEPUBReader()
        let box = Box()
        let id = EPUBTestWindowID.fresh()
        let c = EPUBReaderWindowController(
            book: .g51Fixture(id: id, title: "一巻"), reader: reader,
            settings: freshSettings(), holdsPersistUntilMoved: holds,
            persist: { box.persisted.append($0) })
        c.bindings = .defaults
        c.resumeSheetPresenter = { _, _ in nil }
        return (c, reader, box, id)
    }

    private func prepared(id: Int, holds: Bool) -> (EPUBReaderWindowController.PreparedBook, FakeEPUBReader, Box) {
        let reader = FakeEPUBReader()
        let box = Box()
        let p = EPUBReaderWindowController.PreparedBook(
            book: .g51Fixture(id: id, title: "二巻"), reader: reader, resumeLocator: nil,
            persist: { box.persisted.append($0) }, holdsPersistUntilMoved: holds)
        return (p, reader, box)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func heldBookIsNotSavedWhenClosedWithoutMoving() {
        let (c, reader, box, id) = make(holds: true)
        defer { EPUBTestWindowID.clearFrame(id) }
        reader.locator = loc(0, 0)
        reader.onLocatorChange?(loc(0, 0))
        c.window?.close()
        #expect(box.persisted.isEmpty)
    }

    /// 開いてすぐ（デバウンスの 0.4 秒より前に）送っても、その移動は保存される。
    @Test func heldBookIsSavedOnceTheReaderMoves() {
        let (c, reader, box, id) = make(holds: true)
        defer { EPUBTestWindowID.clearFrame(id) }
        reader.onLocatorChange?(loc(0, 0))
        reader.onLocatorChange?(loc(0, 0.1))
        c.window?.close()
        #expect(box.persisted == [loc(0, 0.1)])
    }

    @Test func normalBookIsSavedAsBefore() {
        let (c, reader, box, id) = make(holds: false)
        defer { EPUBTestWindowID.clearFrame(id) }
        reader.onLocatorChange?(loc(0, 0))
        c.window?.close()
        #expect(box.persisted == [loc(0, 0)])
    }

    /// 普通の本 → manifest なしの本へ差し替え: 古い本は 1 回保存、新しい本は動くまで保存しない。
    @Test func swapIntoAHeldBookHoldsTheNewBookOnly() async {
        let (c, old, oldBox, id) = make(holds: false)
        defer { EPUBTestWindowID.clearFrame(id) }
        old.locator = loc(3, 0.5)
        let (next, new, newBox) = prepared(id: 2, holds: true)
        c.resolveSibling = { _, _ in .swapIn(next) }
        c.perform(.nextVolume)
        await waitUntil { c.book.id == 2 }
        new.locator = loc(0, 0)
        new.onLocatorChange?(loc(0, 0))
        c.window?.close()
        #expect(oldBox.persisted == [loc(3, 0.5)])
        #expect(newBox.persisted.isEmpty)
    }

    /// manifest なしの本 → 普通の本へ差し替え: 門は作り直され、新しい本は今までどおり保存される。
    @Test func swapOutOfAHeldBookResetsTheGate() async {
        let (c, old, oldBox, id) = make(holds: true)
        defer { EPUBTestWindowID.clearFrame(id) }
        old.onLocatorChange?(loc(0, 0))
        old.locator = loc(0, 0)
        let (next, new, newBox) = prepared(id: 2, holds: false)
        c.resolveSibling = { _, _ in .swapIn(next) }
        c.perform(.nextVolume)
        await waitUntil { c.book.id == 2 }
        new.onLocatorChange?(loc(0, 0))
        c.window?.close()
        #expect(oldBox.persisted.isEmpty)          // 動いていないので古い本は送らない
        #expect(newBox.persisted == [loc(0, 0)])
    }
}
