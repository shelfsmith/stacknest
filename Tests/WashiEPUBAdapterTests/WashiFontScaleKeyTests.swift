// SPDX-License-Identifier: MIT
import AppKit
import Testing
@testable import WashiEPUBAdapter

/// ⌘+/⌘-/⌘0 のフォント倍率キー判定は keyCode ではなく文字で行う（G48-2 実機不具合の修正）。
/// keyCode は US 配列前提（24/27/29）で、JIS では ⌘= が別 keyCode に割り当たるため効かなかった。
@Suite("Washi フォント倍率キーの判定（US/JIS 配列）")
struct WashiFontScaleKeyTests {

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        charactersIgnoringModifiers: String,
        command: Bool
    ) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test("US 配列: ⌘= で拡大（Shift なしの素の = キー）")
    func usCommandEqual() {
        // US キーボードの "=" キー。keyCode 24、Shift なしなら characters == charactersIgnoringModifiers == "="。
        let event = keyEvent(keyCode: 24, characters: "=", charactersIgnoringModifiers: "=", command: true)
        #expect(WashiReaderHost.fontScaleDelta(for: event) == 0.1)
    }

    @Test("US 配列: ⌘Shift+= (⌘+) で拡大")
    func usCommandShiftPlus() {
        let event = keyEvent(keyCode: 24, characters: "+", charactersIgnoringModifiers: "=", command: true)
        #expect(WashiReaderHost.fontScaleDelta(for: event) == 0.1)
    }

    @Test("US 配列: ⌘- で縮小")
    func usCommandMinus() {
        let event = keyEvent(keyCode: 27, characters: "-", charactersIgnoringModifiers: "-", command: true)
        #expect(WashiReaderHost.fontScaleDelta(for: event) == -0.1)
    }

    @Test("JIS 配列: keyCode 24 は ^ キー（US の = ではない）なので ⌘^ はフォント倍率キーではない")
    func jisCommandCaret() {
        // JIS の keyCode 24 は "^"（US の "="ではない）。command と組み合わせても対象外。
        let event = keyEvent(keyCode: 24, characters: "^", charactersIgnoringModifiers: "^", command: true)
        #expect(WashiReaderHost.fontScaleDelta(for: event) == nil)
    }

    @Test("JIS 配列: ⌘Shift+;（keyCode 41）は characters が + になるため拡大")
    func jisCommandShiftSemicolon() {
        // JIS の ";" キー（keyCode 41）。Shift 併用で characters は "+"、
        // charactersIgnoringModifiers は素の ";" のまま。
        let event = keyEvent(keyCode: 41, characters: "+", charactersIgnoringModifiers: ";", command: true)
        #expect(WashiReaderHost.fontScaleDelta(for: event) == 0.1)
    }

    @Test("JIS 配列: ⌘;（Shift なし）でも charactersIgnoringModifiers の ; を拾って拡大")
    func jisCommandSemicolonNoShift() {
        let event = keyEvent(keyCode: 41, characters: ";", charactersIgnoringModifiers: ";", command: true)
        #expect(WashiReaderHost.fontScaleDelta(for: event) == 0.1)
    }

    @Test("⌘0 は配列に依らず等倍リセット（delta 0）")
    func commandZero() {
        let event = keyEvent(keyCode: 29, characters: "0", charactersIgnoringModifiers: "0", command: true)
        #expect(WashiReaderHost.fontScaleDelta(for: event) == 0)
    }

    @Test("⌘ 未押下なら常に nil（フォント倍率キーではない）")
    func noCommandModifier() {
        let event = keyEvent(keyCode: 24, characters: "=", charactersIgnoringModifiers: "=", command: false)
        #expect(WashiReaderHost.fontScaleDelta(for: event) == nil)
    }

    @Test("⌘_（Shift+-）でも縮小として拾う")
    func commandUnderscore() {
        let event = keyEvent(keyCode: 27, characters: "_", charactersIgnoringModifiers: "-", command: true)
        #expect(WashiReaderHost.fontScaleDelta(for: event) == -0.1)
    }
}
