// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("ResumeGate — ⌘⇧O の分岐判定")
struct ResumeGateTests {
    @Test("未施錠なら常に本を開く")
    func unlockedLibraryAlwaysOpens() {
        #expect(ResumeGate.decide(isLocked: false, isUnlocked: false) == .openBook)
        #expect(ResumeGate.decide(isLocked: false, isUnlocked: true) == .openBook)
    }

    @Test("施錠かつ未解錠なら解錠まで保留する")
    func lockedAndNotUnlockedDefers() {
        #expect(ResumeGate.decide(isLocked: true, isUnlocked: false) == .deferUntilUnlock)
    }

    @Test("施錠でも解錠済みなら本を開く")
    func lockedButUnlockedOpens() {
        #expect(ResumeGate.decide(isLocked: true, isUnlocked: true) == .openBook)
    }

    @Test("本を開く判定は「未施錠 または 解錠済み」と等価")
    func decisionMatchesLockSemantics() {
        for locked in [false, true] {
            for unlocked in [false, true] {
                let expected: ResumeGate.Decision = (!locked || unlocked) ? .openBook : .deferUntilUnlock
                #expect(ResumeGate.decide(isLocked: locked, isUnlocked: unlocked) == expected)
            }
        }
    }
}
