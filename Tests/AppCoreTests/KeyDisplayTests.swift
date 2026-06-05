// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("KeyDisplay — chord/character to human string")
struct KeyDisplayTests {
    @Test func plainKeys() {
        #expect(KeyDisplay.chord(KeyChord(keyCode: 49)) == "Space")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 125)) == "↓")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 126)) == "↑")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 123)) == "←")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 124)) == "→")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 115)) == "Home")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 119)) == "End")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 116)) == "PageUp")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 121)) == "PageDown")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 48)) == "Tab")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 53)) == "Esc")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 24)) == "=")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 27)) == "-")
    }
    @Test func modifierOrderAndSymbols() {
        #expect(KeyDisplay.chord(KeyChord(keyCode: 13, modifiers: KeyChord.command)) == "⌘W")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 3, modifiers: KeyChord.command | KeyChord.control)) == "⌃⌘F")
        #expect(KeyDisplay.chord(KeyChord(keyCode: 49, modifiers: KeyChord.shift)) == "⇧Space")
    }
    @Test func unknownKeyCodeFallback() {
        #expect(KeyDisplay.chord(KeyChord(keyCode: 9999)) == "key9999")
    }
    @Test func characters() {
        #expect(KeyDisplay.character("+") == "+")
        #expect(KeyDisplay.character("d") == "d")
        #expect(KeyDisplay.character("?") == "?")
    }
}
