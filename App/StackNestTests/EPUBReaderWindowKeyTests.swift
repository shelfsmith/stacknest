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
    /// 専用の suite（実ユーザーの設定に依存しない）。見開きの既定は OFF にしておく
    /// （G57 で開くときに `columnMode` が決まるようになったため。OFF は単ページ〔`.single`〕で開く）。
    private func freshSettings() -> ViewerSettings {
        let name = "g51-epub-keys-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        let s = ViewerSettings(defaults: ud)
        s.spreadByDefault = false
        return s
    }
    private func make(settings: ViewerSettings? = nil) -> (EPUBReaderWindowController, FakeEPUBReader) {
        let reader = FakeEPUBReader()
        let book = BookRow.g51Fixture(id: EPUBTestWindowID.fresh(), title: "t")
        let c = EPUBReaderWindowController(book: book, reader: reader, settings: settings ?? freshSettings(),
                                           persist: { _ in })
        c.bindings = .defaults   // UserDefaults に依存しない
        return (c, reader)
    }

    @Test func spaceAndArrowsUseTheSharedTable() {
        let (c, r) = make()
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        #expect(c.handleKey(key(49, chars: " ")) == true)                 // Space → nextPage
        #expect(c.handleKey(key(49, chars: " ", shift: true)) == true)    // ⇧Space → previousPage
        #expect(c.handleKey(key(124)) == true)                            // → pageRightward
        #expect(c.handleKey(key(123)) == true)                            // ← pageLeftward
        #expect(r.calls == ["goForward", "goBackward", "pageRight", "pageLeft"])
    }

    @Test func homeEndGoToBookEdges() {
        let (c, r) = make()
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        #expect(c.handleKey(key(115)) == true)
        #expect(c.handleKey(key(119)) == true)
        #expect(r.calls == ["goToBookStart", "goToBookEnd"])
    }

    @Test func zoomKeysChangeFontScale() {
        let (c, r) = make()
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        _ = c.handleKey(key(24, chars: "+"))
        _ = c.handleKey(key(27, chars: "-"))
        _ = c.handleKey(key(24, chars: "="))
        #expect(r.calls == ["adjustFontScale(0.1)", "adjustFontScale(-0.1)", "resetFontScale"])
    }

    @Test func spreadToggles() {
        let (c, r) = make()
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        _ = c.handleKey(key(2, chars: "d"))
        #expect(r.columnMode == .double)
        _ = c.handleKey(key(2, chars: "d"))
        #expect(r.columnMode == .single)
        #expect(c.lastHUDNote == "単ページ")
    }

    @Test func percentJumpUsesCensusThenSpineFallback() {
        let (c, r) = make()
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
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
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        #expect(c.handleKey(key(37, chars: "l")) == false)   // toggleLoupe: EPUB では無視 → 上へ
        #expect(r.calls.isEmpty)
    }

    /// G57: Tab／⇧Tab は「Tab スキップのページ数」だけ本全体のページを進める・戻す（先頭・末尾で止める）。
    @Test func tabSkipsByGlobalPagesAfterCensus() {
        let settings = freshSettings()
        settings.tabSkipPageCount = 10
        let (c, r) = make(settings: settings)
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        r.globalPageCount = 200
        r.currentGlobalPageRange = 40...41                   // 見開きでも基点は開始ページ
        #expect(c.handleKey(key(48)) == true)                // Tab → skipForward
        #expect(c.handleKey(key(48, shift: true)) == true)   // ⇧Tab → skipBackward
        r.currentGlobalPageRange = 195...196
        _ = c.handleKey(key(48))
        r.currentGlobalPageRange = 3...3
        _ = c.handleKey(key(48, shift: true))
        #expect(r.calls == ["go(toGlobalPage:50)", "go(toGlobalPage:30)",
                            "go(toGlobalPage:199)", "go(toGlobalPage:0)"])
    }

    /// G57: 計測前は動かさず、ノートで知らせる（章単位の代替はしない）。
    @Test func tabSkipBeforeCensusShowsNoteAndStays() {
        let (c, r) = make()
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        r.spineItemCount = 10
        #expect(c.handleKey(key(48)) == true)
        #expect(r.calls.isEmpty)
        #expect(c.lastHUDNote == "計測中のためページ数では移動できません")
    }

    @Test func unboundKeyIsNotConsumed() {
        let (c, r) = make()
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        #expect(c.handleKey(key(6, chars: "z")) == false)
        #expect(r.calls.isEmpty)
    }

    /// C1: ⌘/⌃/⌥ 付きのキーは `charactersIgnoringModifiers` のフォールバックへ流してはいけない
    /// （⌘1 が「1」に化けてレーティングの代わりに %ジャンプになる、⌘D がメニューではなく
    /// toggleSpread になる、等）。⌘W のようなチョード登録済みのものは従来どおり効く。
    @Test func commandModifiedKeysAreLeftToMenus() {
        let (c, r) = make()
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        #expect(c.handleKey(key(18, chars: "1", command: true)) == false)   // ⌘1 = rating, not a percent jump
        #expect(c.handleKey(key(2, chars: "d", command: true)) == false)    // ⌘D = menu, not toggleSpread
        #expect(c.handleKey(key(13, command: true)) == true)                // ⌘W stays (chord-mapped close)
        #expect(r.calls.isEmpty)
        #expect(r.columnMode == .single)
    }

    @Test func rebindingIsHonored() {
        let (c, r) = make()
        defer { EPUBTestWindowID.clearFrame(c.book.id) }
        var b = ViewerKeyBindings.defaults
        b.remove(.chord(KeyChord(keyCode: 49)), from: .nextPage)   // Space を外す
        _ = b.assign(.character("z"), to: .nextPage)
        c.bindings = b
        #expect(c.handleKey(key(49, chars: " ")) == false)          // 外した Space は EPUB でも送らない
        #expect(c.handleKey(key(6, chars: "z")) == true)
        #expect(r.calls == ["goForward"])
    }
}
