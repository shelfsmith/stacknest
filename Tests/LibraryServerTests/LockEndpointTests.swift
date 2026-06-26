// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
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

    /// DELETE /lock removes hash and salt.
    /// Note: POST the lock through the app first so the served library is captured
    /// as unlocked (isLocked is snapshotted at servedLibrary() time). Pre-seeding the
    /// hash before servedLibrary() would mark the library locked and the resolver would
    /// require a library token, which is out of scope for this test.
    @Test func deleteLockRemovesHash() async throws {
        let fixture = try TestLibraryFixture(name: "LockDel", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)
        let lockBody = try JSONEncoder().encode(LockRequest(password: "secret123"))
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
            // Then remove it via DELETE.
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/lock",
                method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .noContent)
            }
        }
        let hash = try fixture.db.getLibrarySetting(key: "lock_password_hash")
        #expect(hash == nil)
        let salt = try fixture.db.getLibrarySetting(key: "lock_password_salt")
        #expect(salt == nil)
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
