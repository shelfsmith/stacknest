// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("KeyCaptureClassifier")
struct KeyCaptureTests {
    @Test func commandGoesToChord() {
        let r = KeyCaptureClassifier.classify(keyCode: 13, modifiers: KeyChord.command, characters: "w")
        #expect(r == .chord(KeyChord(keyCode: 13, modifiers: KeyChord.command)))
    }
    @Test func controlCommandGoesToChord() {
        let r = KeyCaptureClassifier.classify(keyCode: 3, modifiers: KeyChord.command | KeyChord.control, characters: "f")
        #expect(r == .chord(KeyChord(keyCode: 3, modifiers: KeyChord.command | KeyChord.control)))
    }
    @Test func printableNoModGoesToCharacter() {
        #expect(KeyCaptureClassifier.classify(keyCode: 2, modifiers: 0, characters: "d") == .character("d"))
    }
    @Test func shiftPrintableGoesToCharacter() {
        #expect(KeyCaptureClassifier.classify(keyCode: 35, modifiers: KeyChord.shift, characters: "P") == .character("P"))
    }
    @Test func arrowGoesToChord() {
        #expect(KeyCaptureClassifier.classify(keyCode: 123, modifiers: 0, characters: nil) == .chord(KeyChord(keyCode: 123)))
    }
    @Test func spaceGoesToChord() {
        #expect(KeyCaptureClassifier.classify(keyCode: 49, modifiers: 0, characters: " ") == .chord(KeyChord(keyCode: 49)))
    }
    @Test func optionGoesToChord() {
        #expect(KeyCaptureClassifier.classify(keyCode: 2, modifiers: KeyChord.option, characters: "d") == .chord(KeyChord(keyCode: 2, modifiers: KeyChord.option)))
    }
}
