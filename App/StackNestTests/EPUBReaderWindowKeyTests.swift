// SPDX-License-Identifier: MIT
import AppKit
import Testing
import AppCore
import EPUBAdapter
import LibraryStore
@testable import StackNest

/// G51: EPUB の窓が**共有の割り当て表**でキーを解決し、契約経由で実行する（spec §3.3）。
@MainActor
@Suite("G51: EPUB 窓のキー → アクション")
struct EPUBReaderWindowKeyTests {
    private func key(_ keyCode: UInt16, chars: String = "", shift: Bool = false, command: Bool = false) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }
        if command { flags.insert(.command) }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: 0, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }
    private func make() -> (EPUBReaderWindowController, FakeEPUBReader) {
        let reader = FakeEPUBReader()
        let book = BookRow.g51Fixture(id: 1, title: "t")
        let c = EPUBReaderWindowController(book: book, reader: reader, persist: { _ in })
        c.bindings = .defaults   // UserDefaults に依存しない
        return (c, reader)
    }

    @Test func spaceAndArrowsUseTheSharedTable() {
        let (c, r) = make()
        #expect(c.handleKey(key(49, chars: " ")) == true)                 // Space → nextPage
        #expect(c.handleKey(key(49, chars: " ", shift: true)) == true)    // ⇧Space → previousPage
        #expect(c.handleKey(key(124)) == true)                            // → pageRightward
        #expect(c.handleKey(key(123)) == true)                            // ← pageLeftward
        #expect(r.calls == ["goForward", "goBackward", "pageRight", "pageLeft"])
    }

    @Test func homeEndGoToBookEdges() {
        let (c, r) = make()
        #expect(c.handleKey(key(115)) == true)
        #expect(c.handleKey(key(119)) == true)
        #expect(r.calls == ["goToBookStart", "goToBookEnd"])
    }

    @Test func zoomKeysChangeFontScale() {
        let (c, r) = make()
        _ = c.handleKey(key(24, chars: "+"))
        _ = c.handleKey(key(27, chars: "-"))
        _ = c.handleKey(key(24, chars: "="))
        #expect(r.calls == ["adjustFontScale(0.1)", "adjustFontScale(-0.1)", "resetFontScale"])
    }

    @Test func spreadToggles() {
        let (c, r) = make()
        _ = c.handleKey(key(2, chars: "d"))
        #expect(r.columnMode == .double)
        _ = c.handleKey(key(2, chars: "d"))
        #expect(r.columnMode == .single)
        #expect(c.lastHUDNote == "単ページ")
    }

    @Test func percentJumpUsesCensusThenSpineFallback() {
        let (c, r) = make()
        r.globalPageCount = 200
        _ = c.handleKey(key(23, chars: "5"))
        #expect(r.calls.last == "go(toGlobalPage:100)")
        r.globalPageCount = nil
        r.spineItemCount = 10
        _ = c.handleKey(key(23, chars: "5"))
        #expect(r.calls.last == "go(spine:5,progress:0.0)")
    }

    @Test func unsupportedActionsAreNotConsumed() {
        let (c, r) = make()
        #expect(c.handleKey(key(37, chars: "l")) == false)   // toggleLoupe: EPUB では無視 → 上へ
        #expect(c.handleKey(key(48)) == false)               // Tab（skipForward）: 無視
        #expect(r.calls.isEmpty)
    }

    @Test func unboundKeyIsNotConsumed() {
        let (c, r) = make()
        #expect(c.handleKey(key(6, chars: "z")) == false)
        #expect(r.calls.isEmpty)
    }

    @Test func rebindingIsHonored() {
        let (c, r) = make()
        var b = ViewerKeyBindings.defaults
        b.remove(.chord(KeyChord(keyCode: 49)), from: .nextPage)   // Space を外す
        _ = b.assign(.character("z"), to: .nextPage)
        c.bindings = b
        #expect(c.handleKey(key(49, chars: " ")) == false)          // 外した Space は EPUB でも送らない
        #expect(c.handleKey(key(6, chars: "z")) == true)
        #expect(r.calls == ["goForward"])
    }
}
