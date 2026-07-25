// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("LibraryLock — hash + biometric")
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

    // MARK: - G23: 定数時間比較

    /// G23: 長さが違っても早期 return せず全バイト走査する。
    @Test
    func constantTimeEqualsLengthMismatch() {
        #expect(LibraryLock.constantTimeEquals("abc", "abcd") == false)
        #expect(LibraryLock.constantTimeEquals("", "a") == false)
        #expect(LibraryLock.constantTimeEquals("a", "") == false)
    }

    @Test
    func constantTimeEqualsValues() {
        #expect(LibraryLock.constantTimeEquals("deadbeef", "deadbeef") == true)
        #expect(LibraryLock.constantTimeEquals("deadbeef", "deadbeee") == false)
        #expect(LibraryLock.constantTimeEquals("", "") == true)
    }

    /// G23: verify が定数時間比較を経由しても判定結果は変わらない。
    @Test
    func verifyUsesConstantTimeComparison() {
        let salt = LibraryLock.generateSalt()
        let hash = LibraryLock.computeHash(password: "correct horse", saltHex: salt)
        #expect(LibraryLock.verify(password: "correct horse", saltHex: salt, against: hash) == true)
        #expect(LibraryLock.verify(password: "wrong horse", saltHex: salt, against: hash) == false)
    }

    /// 2.6g: 旧 Keychain item の purge。存在しない item でも throw / crash しない（best-effort）。
    @Test
    func purgeLegacyKeychainItemIsSafeWhenAbsent() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).stacknest")
        LibraryLock.purgeLegacyKeychainItem(bundleURL: url)   // should not throw or crash
    }
}
