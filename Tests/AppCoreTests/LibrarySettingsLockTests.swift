// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings lock fields")
struct LibrarySettingsLockTests {
    private func makeFreshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("libsettings_lock_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: dbURL, mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test
    func defaultsAreNoPassword() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(s.lockPasswordHash == nil)
        #expect(s.lockPasswordSalt == nil)
        #expect(s.useBiometric == false)
    }

    @Test
    func persistsAndReloadsHashSaltBiometric() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(try s.setLock(hash: "deadbeef", salt: "cafebabe", expectedHash: nil))
        s.useBiometric = true
        let r = try LibrarySettings(database: db)
        #expect(r.lockPasswordHash == "deadbeef")
        #expect(r.lockPasswordSalt == "cafebabe")
        #expect(r.useBiometric == true)
    }

    @Test
    func clearingHashRemovesAllLockData() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(try s.setLock(hash: "deadbeef", salt: "cafebabe", expectedHash: nil))
        s.useBiometric = true
        #expect(try s.clearLock(expectedHash: "deadbeef"))
        s.useBiometric = false
        let r = try LibrarySettings(database: db)
        #expect(r.lockPasswordHash == nil)
        #expect(r.lockPasswordSalt == nil)
        #expect(r.useBiometric == false)
    }

    // MARK: - G27a task 8 (Codex High #1): compare-and-set 意味論そのものの検証

    /// 新規施錠は「hash キーがまだ存在しない」ことを条件にする。二重の同時「新規施錠」の
    /// 後発側は拒否され、DB は先着側の値のまま残る。
    @Test
    func setLockWithNilExpectedRejectsWhenAlreadyLocked() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(try s.setLock(hash: "first", salt: "saltA", expectedHash: nil))
        // 後発の「新規施錠」: 既に鍵があるので nil 条件は成立しない。
        #expect(try s.setLock(hash: "attacker", salt: "saltB", expectedHash: nil) == false)
        // メモリも DB も先着側の値のまま。
        #expect(s.lockPasswordHash == "first")
        #expect(s.lockPasswordSalt == "saltA")
        let r = try LibrarySettings(database: db)
        #expect(r.lockPasswordHash == "first")
        #expect(r.lockPasswordSalt == "saltA")
    }

    /// 検証に使った hash が既に古い（他者が変更済み）状態で setLock すると拒否され、
    /// DB は「第三者の変更後」の値のまま残る ―― これが finding #1 の core シナリオ:
    /// ①攻撃者が旧パスワードで検証を通す → ②正規利用者が先に変更 →
    /// ③攻撃者の書き込みが古い expectedHash で試みられる → 拒否されるべき。
    @Test
    func setLockRejectsStaleExpectedHashAndLeavesConcurrentChangeIntact() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(try s.setLock(hash: "original", salt: "saltOrig", expectedHash: nil))

        // ②正規利用者が先に変更（別の LibrarySettings インスタンス・実運用の別プロセス相当）。
        let legit = try LibrarySettings(database: db)
        #expect(try legit.setLock(hash: "legit-new", salt: "saltLegit", expectedHash: "original"))

        // ③攻撃者側は "original" を検証した古いスナップショットのまま書き込みを試みる。
        #expect(try s.setLock(hash: "attacker-new", salt: "saltAttacker", expectedHash: "original") == false)

        // DB は正規利用者の変更のまま ―― 攻撃者の値には一切書き換わっていない。
        let r = try LibrarySettings(database: db)
        #expect(r.lockPasswordHash == "legit-new")
        #expect(r.lockPasswordSalt == "saltLegit")
        // 拒否された側のメモリも DB の実情へ再同期される（stale なままにしない）。
        #expect(s.lockPasswordHash == "legit-new")
        #expect(s.lockPasswordSalt == "saltLegit")
    }

    /// clearLock も同じ compare-and-set: 古い expectedHash では拒否され、
    /// DB は第三者の変更後の値のまま残る（解除で攻撃者が正規の変更を消し飛ばせない）。
    @Test
    func clearLockRejectsStaleExpectedHashAndLeavesConcurrentChangeIntact() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(try s.setLock(hash: "original", salt: "saltOrig", expectedHash: nil))

        let legit = try LibrarySettings(database: db)
        #expect(try legit.setLock(hash: "legit-new", salt: "saltLegit", expectedHash: "original"))

        #expect(try s.clearLock(expectedHash: "original") == false)

        let r = try LibrarySettings(database: db)
        #expect(r.lockPasswordHash == "legit-new")
        #expect(r.lockPasswordSalt == "saltLegit")
    }

    /// G27a task 8 の設計判断: 遅延 PBKDF2 移行（`upgradeLockHash`）が hash を書き換えた**後**、
    /// その移行後の値を expectedHash として使えば setLock は正しく成功する ――
    /// 「移行は検証した本人による正当な値更新」であり、compare-and-set の対象外にしてはいけない。
    @Test
    func setLockSucceedsWithPostUpgradeHashAsExpected() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(try s.setLock(hash: "legacy-hash", salt: "saltOrig", expectedHash: nil))

        // upgradeLockHash が「legacy-hash」から「upgraded-hash」へ CAS で書き換える
        // （LibraryServerDataSource.verifiedCredential の内部と同じ操作）。
        #expect(s.upgradeLockHash(verifiedAgainst: "legacy-hash", to: "upgraded-hash"))
        #expect(s.lockPasswordHash == "upgraded-hash")

        // 移行後の値を expectedHash に使えば、変更は正しく成功する。
        #expect(try s.setLock(hash: "changed-hash", salt: "saltNew", expectedHash: "upgraded-hash"))
        #expect(s.lockPasswordHash == "changed-hash")

        // 対照: 移行前の値をそのまま expectedHash に使うと（呼び出し側が返り値を無視した場合の
        // バグを想定）、移行後の DB とは一致しないので正しく拒否される。
        #expect(try s.setLock(hash: "should-not-apply", salt: "saltX", expectedHash: "legacy-hash") == false)
        #expect(s.lockPasswordHash == "changed-hash")
    }
}
