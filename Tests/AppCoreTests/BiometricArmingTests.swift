// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("BiometricArming — decision + store")
struct BiometricArmingTests {

    @Test
    func decisionUnlocksWhenArmedHashMatches() {
        #expect(decideBiometricUnlock(armedHash: "abc", currentHash: "abc") == .unlock)
    }

    @Test
    func decisionRequiresPasswordWhenNotArmed() {
        #expect(decideBiometricUnlock(armedHash: nil, currentHash: "abc") == .requirePassword)
    }

    @Test
    func decisionRequiresPasswordWhenArmedHashEmpty() {
        #expect(decideBiometricUnlock(armedHash: "", currentHash: "abc") == .requirePassword)
    }

    @Test
    func decisionRequiresPasswordWhenHashChanged() {
        #expect(decideBiometricUnlock(armedHash: "old", currentHash: "new") == .requirePassword)
    }

    @Test
    func storeRoundTrip() {
        let defaults = UserDefaults(suiteName: "arm-test-\(UUID().uuidString)")!
        let store = BiometricArmStore(defaults: defaults)
        #expect(store.armedHash(forLibrary: "lib1") == nil)
        store.arm(library: "lib1", hash: "h1")
        #expect(store.armedHash(forLibrary: "lib1") == "h1")
        store.disarm(library: "lib1")
        #expect(store.armedHash(forLibrary: "lib1") == nil)
    }

    @Test
    func storeIsolatesKeys() {
        let defaults = UserDefaults(suiteName: "arm-test-\(UUID().uuidString)")!
        let store = BiometricArmStore(defaults: defaults)
        store.arm(library: "lib1", hash: "h1")
        store.arm(library: "lib2", hash: "h2")
        #expect(store.armedHash(forLibrary: "lib1") == "h1")
        #expect(store.armedHash(forLibrary: "lib2") == "h2")
        store.disarm(library: "lib1")
        #expect(store.armedHash(forLibrary: "lib1") == nil)
        #expect(store.armedHash(forLibrary: "lib2") == "h2")
    }
}
