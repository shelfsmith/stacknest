// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ViewerKeyBindings mutation + persistence")
struct ViewerKeyBindingsMutationTests {
    @Test func boundBindingsForDefaults() {
        let b = ViewerKeyBindings.defaults
        let nav = b.boundBindings(for: .nextPage)
        #expect(nav.contains(.chord(KeyChord(keyCode: 49))))   // Space
        #expect(nav.contains(.chord(KeyChord(keyCode: 125))))  // ↓
    }
    @Test func assignToFreeKeySucceeds() {
        var b = ViewerKeyBindings(map: [:], characterMap: [:])
        #expect((try? b.assign(.character("x"), to: .nextPage).get()) != nil)
        #expect(b.boundBindings(for: .nextPage) == [.character("x")])
    }
    @Test func assignConflictIsRejected() {
        var b = ViewerKeyBindings(map: [:], characterMap: ["x": .nextPage])
        let result = b.assign(.character("x"), to: .previousPage)
        switch result {
        case .success: Issue.record("should reject")
        case .failure(let conflict): #expect(conflict.existing == .nextPage)
        }
        #expect(b.characterMap["x"] == .nextPage)
    }
    @Test func assignSameActionIsIdempotent() {
        var b = ViewerKeyBindings(map: [:], characterMap: ["x": .nextPage])
        #expect((try? b.assign(.character("x"), to: .nextPage).get()) != nil)
    }
    @Test func chordConflictDetected() {
        var b = ViewerKeyBindings(map: [KeyChord(keyCode: 49): .nextPage], characterMap: [:])
        if case .failure(let c) = b.assign(.chord(KeyChord(keyCode: 49)), to: .previousPage) {
            #expect(c.existing == .nextPage)
        } else { Issue.record("should reject") }
    }
    @Test func removeAndResetAction() {
        var b = ViewerKeyBindings.defaults
        b.remove(.chord(KeyChord(keyCode: 49)), from: .nextPage)
        #expect(!b.boundBindings(for: .nextPage).contains(.chord(KeyChord(keyCode: 49))))
        b.resetAction(.nextPage)
        #expect(b.boundBindings(for: .nextPage).contains(.chord(KeyChord(keyCode: 49))))
    }
    @Test func resetAllRestoresDefaults() {
        var b = ViewerKeyBindings(map: [:], characterMap: [:])
        b.resetAll()
        #expect(b.action(for: KeyChord(keyCode: 49)) == .nextPage)
    }
    @Test func saveLoadRoundTrip() {
        let suite = "test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        var b = ViewerKeyBindings(map: [:], characterMap: [:])
        _ = b.assign(.character("q"), to: .nextPage)
        _ = b.assign(.chord(KeyChord(keyCode: 3, modifiers: KeyChord.command)), to: .close)
        b.save(ud)
        let loaded = ViewerKeyBindings.load(ud)
        #expect(loaded.boundBindings(for: .nextPage) == [.character("q")])
        #expect(loaded.boundBindings(for: .close) == [.chord(KeyChord(keyCode: 3, modifiers: KeyChord.command))])
    }
    @Test func zoomKeysAreCharacterOnlyInDefaults() {
        let b = ViewerKeyBindings.defaults
        #expect(b.boundBindings(for: .fitToWindow) == [.character("=")])
        #expect(b.boundBindings(for: .zoomOut) == [.character("-")])
        #expect(b.boundBindings(for: .zoomIn) == [.character("+")])
    }
    @Test func loadMissingReturnsDefaults() {
        let suite = "test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        let loaded = ViewerKeyBindings.load(ud)
        #expect(loaded.action(for: KeyChord(keyCode: 49)) == .nextPage)
    }
    @Test func escIsFixedToClose() {
        #expect(ViewerKeyBindings.isFixed(.chord(KeyChord(keyCode: 53))))
        #expect(!ViewerKeyBindings.isFixed(.character("f")))
        #expect(ViewerKeyBindings.defaults.boundBindings(for: .close).contains(.chord(KeyChord(keyCode: 53))))
    }
    @Test func removeIgnoresFixedEsc() {
        var b = ViewerKeyBindings.defaults
        b.remove(.chord(KeyChord(keyCode: 53)), from: .close)
        #expect(b.boundBindings(for: .close).contains(.chord(KeyChord(keyCode: 53))), "Esc は固定なので削除されない")
    }
}
