// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import AppCore
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

    /// ライブラリトークンは TTL（テストでは短縮注入）で失効する。
    @Test func libraryTokenExpiresAfterTTL() async throws {
        let store = LibraryTokenStore(ttl: .milliseconds(50))
        let t = await store.issueToken(for: "lib1")
        #expect(await store.isValid(t, for: "lib1"))
        try await Task.sleep(for: .milliseconds(120))
        #expect(!(await store.isValid(t, for: "lib1")))
    }

    /// #2a: グラントの scope 外のライブラリに対する unlock は 404（既存/未存在の判別を与えない）。
    /// A に scope された grant で B の unlock を叩く → 404。同じ grant で A を正しいパスワードで
    /// unlock すると 200（scope 内は既存どおり動作する = regression なし）。
    @Test func unlockOutOfScopeLibraryIs404() async throws {
        let fa = try TestLibraryFixture(name: "UA", bookCount: 1, locked: true, password: "pwA")
        defer { fa.cleanup() }
        let fb = try TestLibraryFixture(name: "UB", bookCount: 1, locked: true, password: "pwB")
        defer { fb.cleanup() }
        let a = fa.servedLibrary(); let b = fb.servedLibrary()
        let g = Grant(id: "g", label: "scopedA", token: "SCA", tier: .edit,
                      scope: .libraries([a.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        let app = LibraryServerCore(
            config: .init(port: 0, token: "unused", editToken: nil, grantsProvider: { [g] }),
            dataSource: StaticLibraryDataSource(libraries: [a, b])
        ).buildApplication()
        try await app.test(.router) { client in
            // scope 外（B）: パスワード違いでも 404（存在の有無を漏らさない）
            try await client.execute(
                uri: "/api/v1/libraries/\(b.uuid)/unlock", method: .post,
                headers: [.authorization: "Bearer SCA"],
                body: .init(string: #"{"password":"pwB"}"#)
            ) { response in
                #expect(response.status == .notFound)
            }
            // scope 内（A）: 正しいパスワードなら従来どおり 200
            try await client.execute(
                uri: "/api/v1/libraries/\(a.uuid)/unlock", method: .post,
                headers: [.authorization: "Bearer SCA"],
                body: .init(string: #"{"password":"pwA"}"#)
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
