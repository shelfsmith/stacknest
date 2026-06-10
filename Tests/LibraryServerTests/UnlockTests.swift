// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("Unlock flow")
struct UnlockTests {
    private func makeLockedFixtureApp() throws -> (TestLibraryFixture, some ApplicationProtocol, String) {
        let fixture = try TestLibraryFixture(name: "Locked", bookCount: 2, locked: true, password: "pw123")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        return (fixture, app, lib.uuid)
    }

    @Test func unlockWithCorrectPasswordIssuesToken() async throws {
        let (fixture, app, uuid) = try makeLockedFixtureApp()
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/unlock", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"password":"pw123"}"#)
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("\"libraryToken\""))
            }
        }
    }

    @Test func unlockWithWrongPasswordIs403() async throws {
        let (fixture, app, uuid) = try makeLockedFixtureApp()
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/unlock", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"password":"nope"}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// ロック庫のリソースはライブラリトークン無しでは 403、unlock 後のトークン付きで 200。
    @Test func lockedLibraryResourcesRequireLibraryToken() async throws {
        let (fixture, app, uuid) = try makeLockedFixtureApp()
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .forbidden)
            }
            var libraryToken = ""
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/unlock", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"password":"pw123"}"#)
            ) { response in
                struct R: Decodable { let libraryToken: String }
                libraryToken = try JSONDecoder().decode(R.self, from: Data(buffer: response.body)).libraryToken
            }
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books", method: .get,
                headers: [.authorization: "Bearer tk",
                          .init("X-Library-Token")!: libraryToken]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// 非ロック庫はライブラリトークン不要。
    @Test func unlockedLibraryNeedsNoLibraryToken() async throws {
        let fixture = try TestLibraryFixture(name: "Open", bookCount: 1)
        defer { fixture.cleanup() }
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(fixture.servedLibrary().uuid)/books", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
