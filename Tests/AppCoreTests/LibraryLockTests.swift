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
        // G23: computeHash は `pbkdf2$<iterations>$<64 桁 hex>` を返す（旧: 生 hex 64 桁）。
        #expect(h1.hasPrefix("pbkdf2$"))
        #expect(h1.split(separator: "$").last?.count == 64)
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

    // MARK: - G23 (#8): PBKDF2 遅延移行

    @Test
    func computeHashProducesPBKDF2Format() {
        let salt = LibraryLock.generateSalt()
        let hash = LibraryLock.computeHash(password: "pw", saltHex: salt)
        #expect(hash.hasPrefix("pbkdf2$\(LibraryLock.pbkdf2Iterations)$"))
    }

    @Test
    func verifyNewFormatNeedsNoUpgrade() {
        let salt = LibraryLock.generateSalt()
        let hash = LibraryLock.computeHash(password: "pw", saltHex: salt)
        #expect(LibraryLock.verifyAndUpgrade(password: "pw", saltHex: salt, against: hash)
                == .ok(upgradedHash: nil))
    }

    /// #8 の要: 旧形式（生 SHA-256 hex）でも解錠でき、その場で新形式へ移行できること。
    @Test
    func verifyLegacyFormatReturnsUpgrade() {
        let salt = LibraryLock.generateSalt()
        let legacy = LibraryLock.legacySHA256Hash(password: "pw", saltHex: salt)
        guard case .ok(let upgraded) = LibraryLock.verifyAndUpgrade(
            password: "pw", saltHex: salt, against: legacy) else {
            Issue.record("旧形式の検証が失敗した")
            return
        }
        #expect(upgraded != nil)
        #expect(upgraded?.hasPrefix("pbkdf2$") == true)
        // 移行後の値でもう一度検証でき、さらなる移行は不要と報告される。
        #expect(LibraryLock.verifyAndUpgrade(password: "pw", saltHex: salt, against: upgraded!)
                == .ok(upgradedHash: nil))
    }

    @Test
    func wrongPasswordFailsBothFormats() {
        let salt = LibraryLock.generateSalt()
        let legacy = LibraryLock.legacySHA256Hash(password: "pw", saltHex: salt)
        let modern = LibraryLock.computeHash(password: "pw", saltHex: salt)
        #expect(LibraryLock.verifyAndUpgrade(password: "nope", saltHex: salt, against: legacy) == .failed)
        #expect(LibraryLock.verifyAndUpgrade(password: "nope", saltHex: salt, against: modern) == .failed)
        #expect(LibraryLock.verify(password: "nope", saltHex: salt, against: legacy) == false)
        #expect(LibraryLock.verify(password: "nope", saltHex: salt, against: modern) == false)
    }

    /// 反復回数が現行値と違う新形式は、正しく検証しつつ現行回数へ作り直す。
    @Test
    func staleIterationCountIsUpgraded() {
        let salt = LibraryLock.generateSalt()
        let weak = LibraryLock.pbkdf2Hash(password: "pw", saltHex: salt, iterations: 1_000)
        guard case .ok(let upgraded) = LibraryLock.verifyAndUpgrade(
            password: "pw", saltHex: salt, against: weak) else {
            Issue.record("低反復の新形式の検証が失敗した")
            return
        }
        #expect(upgraded?.hasPrefix("pbkdf2$\(LibraryLock.pbkdf2Iterations)$") == true)
    }

    /// 壊れた形式（反復回数が数値でない等）は失敗として扱う。
    @Test
    func malformedHashFails() {
        let salt = LibraryLock.generateSalt()
        #expect(LibraryLock.verifyAndUpgrade(password: "pw", saltHex: salt, against: "pbkdf2$abc$dead") == .failed)
        #expect(LibraryLock.verifyAndUpgrade(password: "pw", saltHex: salt, against: "pbkdf2$0$dead") == .failed)
        #expect(LibraryLock.verifyAndUpgrade(password: "pw", saltHex: salt, against: "") == .failed)
    }

    /// 2.6g: 旧 Keychain item の purge。存在しない item でも throw / crash しない（best-effort）。
    @Test
    func purgeLegacyKeychainItemIsSafeWhenAbsent() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).stacknest")
        LibraryLock.purgeLegacyKeychainItem(bundleURL: url)   // should not throw or crash
    }
}
