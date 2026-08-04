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
}
