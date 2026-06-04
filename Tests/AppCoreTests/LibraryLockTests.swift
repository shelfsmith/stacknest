// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("LibraryLock — hash + Keychain")
struct LibraryLockTests {

    @Test
    func saltGeneratesRandomly() throws {
        let salt1 = LibraryLock.generateSalt()
        let salt2 = LibraryLock.generateSalt()
        #expect(salt1.count == 32)
        #expect(salt2.count == 32)
        #expect(salt1 != salt2)
    }

    @Test
    func hashIsDeterministicGivenSamePasswordAndSalt() throws {
        let salt = "abcdef1234567890" + "abcdef1234567890"
        let h1 = LibraryLock.computeHash(password: "secret", saltHex: salt)
        let h2 = LibraryLock.computeHash(password: "secret", saltHex: salt)
        #expect(h1 == h2)
        #expect(h1.count == 64)
    }

    @Test
    func hashDiffersForDifferentPassword() throws {
        let salt = "abcdef1234567890" + "abcdef1234567890"
        let h1 = LibraryLock.computeHash(password: "secret", saltHex: salt)
        let h2 = LibraryLock.computeHash(password: "different", saltHex: salt)
        #expect(h1 != h2)
    }

    @Test
    func verifyMatchesCorrectPassword() throws {
        let salt = LibraryLock.generateSalt()
        let hash = LibraryLock.computeHash(password: "abc", saltHex: salt)
        #expect(LibraryLock.verify(password: "abc", saltHex: salt, against: hash) == true)
        #expect(LibraryLock.verify(password: "xyz", saltHex: salt, against: hash) == false)
    }

    @Test
    func keychainCRUDRoundtrip() throws {
        let testService = "app.shelfsmith.stacknest.lock.tests"
        let testAccount = "test_bundle_url"
        try? LibraryLock.deleteKeychainPassword(service: testService, account: testAccount)
        try LibraryLock.saveKeychainPassword("hello", service: testService, account: testAccount, biometryProtected: false)
        let loaded = try LibraryLock.loadKeychainPassword(service: testService, account: testAccount)
        #expect(loaded == "hello")
        try LibraryLock.saveKeychainPassword("world", service: testService, account: testAccount, biometryProtected: false)
        let updated = try LibraryLock.loadKeychainPassword(service: testService, account: testAccount)
        #expect(updated == "world")
        try LibraryLock.deleteKeychainPassword(service: testService, account: testAccount)
        let afterDelete = try? LibraryLock.loadKeychainPassword(service: testService, account: testAccount)
        #expect(afterDelete == nil || afterDelete == .some(nil))  // 削除後は nil または "no item" のどちらか
    }

    /// Q1-2: biometryProtected: true でも ACL なしで保存できる (errSecMissingEntitlement 解消)。
    /// Keychain item は ACL なしで保存され、biometric gate は app 層 (LAContext) で行う。
    @Test
    func keychainSaveWithBiometryProtectedTrueSucceeds() throws {
        let testService = "app.shelfsmith.stacknest.lock.tests.biometry"
        let testAccount = "test_biometry"
        try? LibraryLock.deleteKeychainPassword(service: testService, account: testAccount)
        // Should NOT throw even with biometryProtected: true (no entitlement required)
        try LibraryLock.saveKeychainPassword("secure123", service: testService, account: testAccount, biometryProtected: true)
        let loaded = try LibraryLock.loadKeychainPassword(service: testService, account: testAccount)
        #expect(loaded == "secure123")
        try LibraryLock.deleteKeychainPassword(service: testService, account: testAccount)
    }

    /// Task 6: per-machine biometric setup — absent item は nil を返す (prompt 判定用)。
    @Test
    func keychainLoadReturnsNilWhenAbsent() throws {
        let testService = "app.shelfsmith.stacknest.lock.tests.absent"
        let testAccount = "test_absent_\(UUID().uuidString)"
        // Ensure not present
        try? LibraryLock.deleteKeychainPassword(service: testService, account: testAccount)
        let result = try LibraryLock.loadKeychainPassword(service: testService, account: testAccount)
        #expect(result == nil)
    }

    /// Task 6: 保存後に読み出し、一致を確認 → 削除後は nil (round-trip for biometric setup path)。
    @Test
    func keychainSaveAndLoadRoundtripForBiometricSetup() throws {
        let testService = "app.shelfsmith.stacknest.lock.tests.setup"
        let testAccount = "test_setup_\(UUID().uuidString)"
        try? LibraryLock.deleteKeychainPassword(service: testService, account: testAccount)

        // Verify absent before save
        let before = try LibraryLock.loadKeychainPassword(service: testService, account: testAccount)
        #expect(before == nil)

        // Save (simulates "設定する" action)
        let plainPassword = "my-library-password"
        try LibraryLock.saveKeychainPassword(plainPassword, service: testService, account: testAccount, biometryProtected: true)

        // Read back
        let after = try LibraryLock.loadKeychainPassword(service: testService, account: testAccount)
        #expect(after == plainPassword)

        // Cleanup
        try LibraryLock.deleteKeychainPassword(service: testService, account: testAccount)
    }
}
