// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import AppCore
@testable import LibraryServer

@Suite("POST/DELETE /lock endpoint")
struct LockEndpointTests {

    private func makeApp(fixture: TestLibraryFixture, adminTier: Bool = false) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    /// POST /lock sets lock_password_hash in DB.
    @Test func postLockSetsHash() async throws {
        let fixture = try TestLibraryFixture(name: "LockSet", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let bodyData = try JSONEncoder().encode(LockRequest(password: "secret123"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .noContent)
            }
        }
        // Verify hash is stored
        let hash = try fixture.db.getLibrarySetting(key: "lock_password_hash")
        #expect(hash != nil)
        let salt = try fixture.db.getLibrarySetting(key: "lock_password_salt")
        #expect(salt != nil)
    }

    /// DELETE /lock removes hash and salt when the correct current password is supplied.
    /// Note: POST the lock through the app first so the served library is captured
    /// as unlocked (isLocked is snapshotted at servedLibrary() time). Pre-seeding the
    /// hash before servedLibrary() would mark the library locked and the resolver would
    /// require a library token, which is out of scope for this test.
    /// G27a Task6: DELETE now requires currentPassword whenever a lock already exists
    /// (checked live against the DB, independent of the stale isLocked snapshot above).
    @Test func deleteLockRemovesHash() async throws {
        let fixture = try TestLibraryFixture(name: "LockDel", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let lockBody = try JSONEncoder().encode(LockRequest(password: "secret123"))
        let removeBody = try JSONEncoder().encode(LockRemoveRequest(currentPassword: "secret123"))
        try await app.test(.router) { client in
            // First set a lock via POST.
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(lockBody))
            ) { response in
                #expect(response.status == .noContent)
            }
            // Then remove it via DELETE, supplying the current password.
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock",
                method: .delete,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(removeBody))
            ) { response in
                #expect(response.status == .noContent)
            }
        }
        let hash = try fixture.db.getLibrarySetting(key: "lock_password_hash")
        #expect(hash == nil)
        let salt = try fixture.db.getLibrarySetting(key: "lock_password_salt")
        #expect(salt == nil)
    }

    /// DELETE /lock on a library that was never locked still succeeds without a body
    /// (regression guard — brief item 1: unlocked libraries need no current password).
    @Test func deleteLockOnNeverLockedLibrarySucceedsWithoutBody() async throws {
        let fixture = try TestLibraryFixture(name: "LockDelNoop", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock",
                method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .noContent)
            }
        }
    }

    /// G27a Task6 (brief item 4): DELETE with the *wrong* current password is rejected AND
    /// leaves the stored hash/salt untouched (not merely "rejected" — actually unchanged).
    @Test func deleteLockWithWrongCurrentPasswordIsForbiddenAndLeavesHashUnchanged() async throws {
        let fixture = try TestLibraryFixture(name: "LockDelWrong", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let lockBody = try JSONEncoder().encode(LockRequest(password: "secret123"))
        let wrongRemoveBody = try JSONEncoder().encode(LockRemoveRequest(currentPassword: "wrongpw"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(lockBody))
            ) { response in #expect(response.status == .noContent) }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .delete,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(wrongRemoveBody))
            ) { response in #expect(response.status == .forbidden) }
        }
        let hashAfter = try fixture.db.getLibrarySetting(key: "lock_password_hash")
        let saltAfter = try fixture.db.getLibrarySetting(key: "lock_password_salt")
        #expect(hashAfter != nil)
        #expect(saltAfter != nil)
        // Still verifies against the ORIGINAL password — proof the write never happened.
        #expect(LibraryLock.verify(password: "secret123", saltHex: saltAfter!, against: hashAfter!))
    }

    /// G27a Task6 (brief item 4): DELETE with a lock present but no currentPassword at all
    /// (e.g. an old client's bare DELETE) is rejected AND leaves the hash/salt untouched.
    @Test func deleteLockWithMissingCurrentPasswordIsForbiddenAndLeavesHashUnchanged() async throws {
        let fixture = try TestLibraryFixture(name: "LockDelMissing", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let lockBody = try JSONEncoder().encode(LockRequest(password: "secret123"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(lockBody))
            ) { response in #expect(response.status == .noContent) }
            // Old-style bare DELETE with no body at all — this is the exact request shape
            // that used to succeed before G27a Task6 and constituted the vulnerability.
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in #expect(response.status == .forbidden) }
        }
        let hashAfter = try fixture.db.getLibrarySetting(key: "lock_password_hash")
        let saltAfter = try fixture.db.getLibrarySetting(key: "lock_password_salt")
        #expect(hashAfter != nil)
        #expect(saltAfter != nil)
        #expect(LibraryLock.verify(password: "secret123", saltHex: saltAfter!, against: hashAfter!))
    }

    // MARK: - G27a Task6: POST /lock (change) now also requires the current password

    /// Brief item 3: changing an existing lock with the CORRECT current password succeeds
    /// and the new password verifies against the stored hash.
    @Test func postLockChangeWithCorrectCurrentPasswordSucceeds() async throws {
        let fixture = try TestLibraryFixture(name: "LockChangeOK", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let initial = try JSONEncoder().encode(LockRequest(password: "secret123"))
        let change = try JSONEncoder().encode(LockRequest(password: "newpassword", currentPassword: "secret123"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(initial))
            ) { response in #expect(response.status == .noContent) }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(change))
            ) { response in #expect(response.status == .noContent) }
        }
        let hash = try fixture.db.getLibrarySetting(key: "lock_password_hash")
        let salt = try fixture.db.getLibrarySetting(key: "lock_password_salt")
        #expect(hash != nil); #expect(salt != nil)
        #expect(LibraryLock.verify(password: "newpassword", saltHex: salt!, against: hash!))
        #expect(!LibraryLock.verify(password: "secret123", saltHex: salt!, against: hash!))
    }

    /// Brief item 2: changing an existing lock with the WRONG current password is rejected
    /// AND leaves the stored hash/salt untouched (this is the vulnerability this task closes —
    /// previously this call silently overwrote the password with no verification at all).
    @Test func postLockChangeWithWrongCurrentPasswordIsForbiddenAndLeavesHashUnchanged() async throws {
        let fixture = try TestLibraryFixture(name: "LockChangeWrong", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let initial = try JSONEncoder().encode(LockRequest(password: "secret123"))
        let change = try JSONEncoder().encode(LockRequest(password: "attacker-password", currentPassword: "wrongpw"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(initial))
            ) { response in #expect(response.status == .noContent) }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(change))
            ) { response in #expect(response.status == .forbidden) }
        }
        let hashAfter = try fixture.db.getLibrarySetting(key: "lock_password_hash")
        let saltAfter = try fixture.db.getLibrarySetting(key: "lock_password_salt")
        #expect(hashAfter != nil); #expect(saltAfter != nil)
        // Original password still verifies; the attacker's password does not.
        #expect(LibraryLock.verify(password: "secret123", saltHex: saltAfter!, against: hashAfter!))
        #expect(!LibraryLock.verify(password: "attacker-password", saltHex: saltAfter!, against: hashAfter!))
    }

    /// Change attempted with no currentPassword field at all (old client shape) is likewise
    /// rejected and leaves the hash/salt untouched.
    @Test func postLockChangeWithMissingCurrentPasswordIsForbiddenAndLeavesHashUnchanged() async throws {
        let fixture = try TestLibraryFixture(name: "LockChangeMissing", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let initial = try JSONEncoder().encode(LockRequest(password: "secret123"))
        // Old-style request shape: no currentPassword at all.
        let change = try JSONEncoder().encode(LockRequest(password: "attacker-password"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(initial))
            ) { response in #expect(response.status == .noContent) }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(change))
            ) { response in #expect(response.status == .forbidden) }
        }
        let hashAfter = try fixture.db.getLibrarySetting(key: "lock_password_hash")
        let saltAfter = try fixture.db.getLibrarySetting(key: "lock_password_salt")
        #expect(hashAfter != nil); #expect(saltAfter != nil)
        #expect(LibraryLock.verify(password: "secret123", saltHex: saltAfter!, against: hashAfter!))
    }

    /// Brief item 1: setting a lock on a library that has none yet still needs no current
    /// password (regression guard for the unaffected path).
    @Test func postLockNewSetupNeedsNoCurrentPassword() async throws {
        let fixture = try TestLibraryFixture(name: "LockNewNoCur", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let bodyData = try JSONEncoder().encode(LockRequest(password: "firstpw"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in #expect(response.status == .noContent) }
        }
        let hash = try fixture.db.getLibrarySetting(key: "lock_password_hash")
        let salt = try fixture.db.getLibrarySetting(key: "lock_password_salt")
        #expect(hash != nil); #expect(salt != nil)
        #expect(LibraryLock.verify(password: "firstpw", saltHex: salt!, against: hash!))
    }

    /// POST /lock with read token → 403.
    @Test func postLockWithReadTokenForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "LockForbidden", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let bodyData = try JSONEncoder().encode(LockRequest(password: "x"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock",
                method: .post,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// POST /lock with empty password → 400.
    @Test func postLockWithEmptyPasswordBadRequest() async throws {
        let fixture = try TestLibraryFixture(name: "LockEmpty", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let bodyData = try JSONEncoder().encode(LockRequest(password: ""))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    // MARK: - G27a task 8 (Codex High #1・TOCTOU): compare-and-set の統合検証

    /// 核心シナリオを、ルートが実際に使う `ServedLibrary`/`Database` の型で直接再現する
    /// （HTTP テストは 1 リクエストが完全に完了してから次が始まるため、真の同時実行は
    /// HTTP レイヤでは再現できない ―― ルートの中身と同じ 2 段（`verifiedCredential` →
    /// `compareAndSetLibrarySettings`）を手動で挟むことで、ルートが依拠する不可分性を検証する）。
    ///
    /// ①攻撃者が旧パスワードで検証を通す（`verified` を得る）→ ②正規利用者が先に変更 →
    /// ③攻撃者の書き込みが古い `verified` で試みられる → 拒否され、DB は②のまま残ること。
    @Test func postLockRaceIsRejectedAndLeavesConcurrentChangeIntact() async throws {
        let fixture = try TestLibraryFixture(name: "LockRace", bookCount: 0, locked: true, password: "secret123")
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()

        // ①攻撃者が正しい旧パスワードで検証を通す（ルートの `verifiedCredential(for:)` 呼び出しに相当）。
        let attackerVerified = try #require(lib.verifiedCredential(for: "secret123"))

        // ②正規利用者が先に変更（実際の POST /lock ルートと同じ経路で更新）。
        let legitSalt = LibraryLock.generateSalt()
        let legitHash = LibraryLock.computeHash(password: "legit-new-password", saltHex: legitSalt)
        #expect(try lib.db.compareAndSetLibrarySettings(
            conditionKey: "lock_password_hash", expectedValue: attackerVerified,
            newValues: ["lock_password_salt": legitSalt, "lock_password_hash": legitHash]))

        // ③攻撃者側の書き込みがルートと同じ CAS 呼び出しで、古い `attackerVerified` を条件に試みられる。
        let attackerSalt = LibraryLock.generateSalt()
        let attackerHash = LibraryLock.computeHash(password: "attacker-password", saltHex: attackerSalt)
        let applied = try lib.db.compareAndSetLibrarySettings(
            conditionKey: "lock_password_hash", expectedValue: attackerVerified,
            newValues: ["lock_password_salt": attackerSalt, "lock_password_hash": attackerHash])
        #expect(!applied, "古い credential での書き込みが受理されてしまっている（TOCTOU が塞がっていない）")

        // DB は②の正規の変更のまま。攻撃者のパスワードでは解錠できない。
        let hashAfter = try #require(try lib.db.getLibrarySetting(key: "lock_password_hash"))
        let saltAfter = try #require(try lib.db.getLibrarySetting(key: "lock_password_salt"))
        #expect(LibraryLock.verify(password: "legit-new-password", saltHex: saltAfter, against: hashAfter))
        #expect(!LibraryLock.verify(password: "attacker-password", saltHex: saltAfter, against: hashAfter))
    }

    /// 同上・DELETE 版。
    @Test func deleteLockRaceIsRejectedAndLeavesConcurrentChangeIntact() async throws {
        let fixture = try TestLibraryFixture(name: "LockDelRace", bookCount: 0, locked: true, password: "secret123")
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()

        let attackerVerified = try #require(lib.verifiedCredential(for: "secret123"))

        // 正規利用者が先に変更（施錠は維持したまま新パスワードへ）。
        let legitSalt = LibraryLock.generateSalt()
        let legitHash = LibraryLock.computeHash(password: "legit-new-password", saltHex: legitSalt)
        #expect(try lib.db.compareAndSetLibrarySettings(
            conditionKey: "lock_password_hash", expectedValue: attackerVerified,
            newValues: ["lock_password_salt": legitSalt, "lock_password_hash": legitHash]))

        // 攻撃者は古い credential でロック解除を試みる。
        let applied = try lib.db.compareAndDeleteLibrarySettings(
            conditionKey: "lock_password_hash", expectedValue: attackerVerified,
            keysToDelete: ["lock_password_hash", "lock_password_salt"])
        #expect(!applied, "古い credential での解除が受理されてしまっている（TOCTOU が塞がっていない）")

        // ロックは正規利用者の新パスワードのまま残っている（消えていない）。
        let hashAfter = try #require(try lib.db.getLibrarySetting(key: "lock_password_hash"))
        let saltAfter = try #require(try lib.db.getLibrarySetting(key: "lock_password_salt"))
        #expect(LibraryLock.verify(password: "legit-new-password", saltHex: saltAfter, against: hashAfter))
    }

    /// G27a task 8 の設計判断（PBKDF2 遅延移行との相互作用）: 保存値が旧形式（SHA-256）のとき、
    /// `verifiedCredential(for:)` は検証と同じ瞬間に移行後のハッシュへ書き換え、**移行後の値**を
    /// 返す。POST /lock ルートはこの返り値を compare-and-set の条件に使うため、移行が起きた直後の
    /// パスワード変更でも「他者に変更された」と誤検知せず正しく成功しなければならない。
    /// これは実際の HTTP ルートを通した end-to-end 検証（内部の CAS 2 段を手動で挟む必要が無い ――
    /// 移行は投機的な競合ではなく、この検証自身が起こす確定的な副作用のため）。
    @Test func postLockChangeSucceedsRightAfterLazyPBKDF2Upgrade() async throws {
        let fixture = try TestLibraryFixture(name: "LockUpgradeThenChange", bookCount: 0)
        defer { fixture.cleanup() }
        // ServedLibrary.isLocked は servedLibrary() 呼び出し時点のスナップショットで、resolver は
        // それが true だと X-Library-Token を要求する（他テストの注記どおり）。したがって
        // servedLibrary()/makeApp が両方とも「未施錠」を見た**後**に、DB へ直接旧形式ハッシュを
        // 仕込む（TestLibraryFixture の locked: は常に現行 PBKDF2 形式を使うため手動で再現する）。
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let salt = LibraryLock.generateSalt()
        let legacyHash = LibraryLock.legacySHA256Hash(password: "secret123", saltHex: salt)
        try fixture.db.setLibrarySetting(key: "lock_password_hash", value: legacyHash)
        try fixture.db.setLibrarySetting(key: "lock_password_salt", value: salt)

        let change = try JSONEncoder().encode(LockRequest(password: "newpassword", currentPassword: "secret123"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(change))
            ) { response in
                #expect(response.status == .noContent,
                        "遅延移行直後の変更が CAS 不一致として誤って拒否されている")
            }
        }
        let hashAfter = try #require(try fixture.db.getLibrarySetting(key: "lock_password_hash"))
        let saltAfter = try #require(try fixture.db.getLibrarySetting(key: "lock_password_salt"))
        // 新パスワードで解錠でき、かつ現行 PBKDF2 形式になっている（旧 SHA-256 のままではない）。
        #expect(LibraryLock.verify(password: "newpassword", saltHex: saltAfter, against: hashAfter))
        #expect(hashAfter.hasPrefix("pbkdf2$"))
    }

    /// **真の同時実行**で POST /lock を 2 本同時に送る（`async let` で両方に同じ正しい現パスワードを
    /// 積み、別々の新パスワードへ変更させる）。両方とも送信時点では検証が通る正しい現パスワードだが、
    /// 書き込みは compare-and-set で直列化されるため、どちらか一方だけが成功（204）し、
    /// もう一方は書き込み時点で条件不一致になり 409（`HTTPError(.conflict)`）を返すこと。
    /// これが finding #1 の TOCTOU が実際に閉じたことの最も直接的な証拠になる
    /// （他のテストは「検証済みの古い値」を手で用意する準統合テストだが、これは本物の並行リクエスト）。
    @Test func postLockConcurrentChangesExactlyOneWinsAndLoserGets409() async throws {
        // ServedLibrary.isLocked のスナップショット問題（上のテスト参照）を避けるため、
        // 未施錠で snapshot させてから、実 POST でロックを設定する（他テストと同じ確立された作法）。
        let fixture = try TestLibraryFixture(name: "LockConcurrent", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let initial = try JSONEncoder().encode(LockRequest(password: "secret123"))
        let changeA = try JSONEncoder().encode(LockRequest(password: "password-A", currentPassword: "secret123"))
        let changeB = try JSONEncoder().encode(LockRequest(password: "password-B", currentPassword: "secret123"))

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(initial))
            ) { response in #expect(response.status == .noContent) }

            async let respA = client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(changeA))
            ) { $0.status }
            async let respB = client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(changeB))
            ) { $0.status }
            let (statusA, statusB) = try await (respA, respB)

            // ちょうど一方が成功(204)・もう一方が競合(409)であること。
            // 「両方 204」＝TOCTOU が残っている（両方の変更が無検証で成立してしまった）。
            // 「両方 409」または他の組み合わせ＝そもそも正常な変更が一本も通っていない。
            let succeeded = [statusA, statusB].filter { $0 == .noContent }.count
            let conflicted = [statusA, statusB].filter { $0 == .conflict }.count
            #expect(succeeded == 1, "成功した本数が 1 ではない: A=\(statusA) B=\(statusB)")
            #expect(conflicted == 1, "競合(409)として拒否された本数が 1 ではない: A=\(statusA) B=\(statusB)")
        }

        // 勝者のパスワードのどちらか一方だけで解錠できる。
        let hashAfter = try #require(try fixture.db.getLibrarySetting(key: "lock_password_hash"))
        let saltAfter = try #require(try fixture.db.getLibrarySetting(key: "lock_password_salt"))
        let aWorks = LibraryLock.verify(password: "password-A", saltHex: saltAfter, against: hashAfter)
        let bWorks = LibraryLock.verify(password: "password-B", saltHex: saltAfter, against: hashAfter)
        #expect(aWorks != bWorks, "ちょうど片方の新パスワードだけが有効であるべき")
    }
}
