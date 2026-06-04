// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ViewerKeyBindings extra (2.6b-2)")
struct ViewerKeyBindingsExtraTests {
    @Test func characterMapResolvesNewActions() {
        let b = ViewerKeyBindings.defaults
        #expect(b.action(forCharacter: "d") == .toggleSpread)
        #expect(b.action(forCharacter: "s") == .toggleAutoAdvance)
        #expect(b.action(forCharacter: "w") == .cyclePageLayout)
        #expect(b.action(forCharacter: "]") == .nextVolume)
        #expect(b.action(forCharacter: "[") == .prevVolume)
        #expect(b.action(forCharacter: "e") == .cycleEndOfBookBehavior)
        #expect(b.action(forCharacter: "P") == .toggleCoverOffset)
    }

    @Test func newActionsShowHUD() {
        for a in [ViewerAction.toggleSpread, .toggleCoverOffset, .toggleAutoAdvance,
                  .cyclePageLayout, .nextVolume, .prevVolume, .cycleEndOfBookBehavior] {
            #expect(a.showsHUD == true, "\(a) should show HUD")
        }
    }

    @Test func caseIterableContainsNewActions() {
        let all = Set(ViewerAction.allCases)
        #expect(all.contains(.toggleSpread))
        #expect(all.contains(.toggleCoverOffset))
        #expect(all.contains(.toggleAutoAdvance))
        #expect(all.contains(.cyclePageLayout))
        #expect(all.contains(.nextVolume))
        #expect(all.contains(.prevVolume))
        #expect(all.contains(.cycleEndOfBookBehavior))
    }

    // Phase 2.6b-2-3: 数字キー 0〜9 のジャンプバインド
    @Test func digitKeysJumpToPercent() {
        let b = ViewerKeyBindings.defaults
        #expect(b.action(forCharacter: "0") == .jumpToPercent0)
        #expect(b.action(forCharacter: "5") == .jumpToPercent50)
        #expect(b.action(forCharacter: "9") == .jumpToPercent90)
        #expect(b.action(forCharacter: "=") == .fitToWindow)
    }

    // Phase 2.6b-2-3: Tab/⇧Tab スキップバインド
    @Test func tabSkipActionsBound() {
        let b = ViewerKeyBindings.defaults
        #expect(b.action(for: KeyChord(keyCode: 48)) == .skipForward)
        #expect(b.action(for: KeyChord(keyCode: 48, modifiers: KeyChord.shift)) == .skipBackward)
    }

    // Phase 2.6b-2-3: 新アクションは HUD を表示する
    @Test func newNavActionsShowHUD() {
        #expect(ViewerAction.jumpToPercent50.showsHUD)
        #expect(ViewerAction.skipForward.showsHUD)
        #expect(ViewerAction.skipBackward.showsHUD)
    }
}
