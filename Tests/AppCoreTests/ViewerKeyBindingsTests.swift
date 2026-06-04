// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ViewerKeyBindings")
struct ViewerKeyBindingsTests {
    @Test func defaultsResolveSpaceToNextPage() {
        let b = ViewerKeyBindings.defaults
        #expect(b.action(for: KeyChord(keyCode: 49)) == .nextPage)
        #expect(b.action(for: KeyChord(keyCode: 49, modifiers: KeyChord.shift)) == .previousPage)
    }
    @Test func defaultsArrowsAreSpatial() {
        let b = ViewerKeyBindings.defaults
        #expect(b.action(for: KeyChord(keyCode: 123)) == .pageLeftward)
        #expect(b.action(for: KeyChord(keyCode: 124)) == .pageRightward)
    }
    @Test func defaultsZoomKeys() {
        let b = ViewerKeyBindings.defaults
        // Phase 2.6b-2-3: keyCode 24 (=) は fitToWindow に変更; keyCode 29 (0) の binding は削除
        #expect(b.action(for: KeyChord(keyCode: 24)) == .fitToWindow)
        #expect(b.action(for: KeyChord(keyCode: 24, modifiers: KeyChord.shift)) == .zoomIn)
        #expect(b.action(for: KeyChord(keyCode: 27)) == .zoomOut)
        #expect(b.action(for: KeyChord(keyCode: 29)) == nil)  // 削除済み → characterMap "0" にフォールスルー
    }
    @Test func defaultsCloseAndFullScreen() {
        let b = ViewerKeyBindings.defaults
        #expect(b.action(for: KeyChord(keyCode: 53)) == .close)
        #expect(b.action(for: KeyChord(keyCode: 13, modifiers: KeyChord.command)) == .close)
        #expect(b.action(for: KeyChord(keyCode: 3, modifiers: KeyChord.command | KeyChord.control)) == .toggleFullScreen)
    }
    @Test func unboundChordReturnsNil() {
        #expect(ViewerKeyBindings.defaults.action(for: KeyChord(keyCode: 200)) == nil)
    }
    @Test func keyChordIsCodableRoundTrip() throws {
        let chord = KeyChord(keyCode: 49, modifiers: KeyChord.shift)
        let data = try JSONEncoder().encode(chord)
        let back = try JSONDecoder().decode(KeyChord.self, from: data)
        #expect(back == chord)
    }
    @Test func bindingsCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(ViewerKeyBindings.defaults)
        let back = try JSONDecoder().decode(ViewerKeyBindings.self, from: data)
        #expect(back.action(for: KeyChord(keyCode: 49)) == .nextPage)
    }
    @Test func characterMapResolvesPrintableZoomKeys() {
        let b = ViewerKeyBindings.defaults
        // Phase 2.6b-2-3: "=" は fitToWindow に変更; "0" は jumpToPercent0 に変更
        #expect(b.action(forCharacter: "+") == .zoomIn)
        #expect(b.action(forCharacter: "=") == .fitToWindow)
        #expect(b.action(forCharacter: "-") == .zoomOut)
        #expect(b.action(forCharacter: "0") == .jumpToPercent0)
        #expect(b.action(forCharacter: "x") == nil)
    }
    @Test func everyActionIsReachableFromDefaults() {
        let b = ViewerKeyBindings.defaults
        let mapped = Set(b.map.values).union(Set(b.characterMap.values))
        for a in ViewerAction.allCases { #expect(mapped.contains(a), "\(a) unbound") }
    }
}
