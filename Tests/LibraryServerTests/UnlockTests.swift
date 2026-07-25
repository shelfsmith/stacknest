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

    /// #2: UnlockRateLimiter は閾値到達でロックアウトし、期限切れ／成功でリセットする。
    /// G23 (M3): キーが library 単体から library＋principal に変わったため principal を明示する。
    @Test func rateLimiterLocksOutAfterThresholdAndResets() async {
        let rl = UnlockRateLimiter(maxFailures: 2, lockoutSeconds: 30)
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(await rl.isLockedOut("L", principal: "p", now: t0) == false)
        await rl.recordFailure("L", principal: "p", now: t0)
        #expect(await rl.isLockedOut("L", principal: "p", now: t0) == false)      // 1 回目 < 閾値
        await rl.recordFailure("L", principal: "p", now: t0)                       // 2 回目で閾値到達 → ロックアウト
        #expect(await rl.isLockedOut("L", principal: "p", now: t0) == true)
        #expect(await rl.isLockedOut("L", principal: "p", now: t0.addingTimeInterval(31)) == false)   // 期限切れで解除
        await rl.recordFailure("L", principal: "p", now: t0.addingTimeInterval(31))
        await rl.recordSuccess("L", principal: "p")                                // 成功で完全リセット
        #expect(await rl.isLockedOut("L", principal: "p", now: t0.addingTimeInterval(31)) == false)
    }

    // MARK: - G23 (M3): principal 単位のロックアウト

    /// M3 の要: ある共有相手の連続失敗が、正当な所有者や他の相手を締め出してはならない。
    @Test func lockoutIsScopedToPrincipal() async {
        let rl = UnlockRateLimiter(maxFailures: 3, lockoutSeconds: 30)
        let t0 = Date(timeIntervalSince1970: 1000)
        for _ in 0..<3 { await rl.recordFailure("L", principal: "attacker", now: t0) }
        #expect(await rl.isLockedOut("L", principal: "attacker", now: t0) == true)
        #expect(await rl.isLockedOut("L", principal: "owner", now: t0) == false)
    }

    /// 同じ principal でも別ライブラリなら独立して数える。
    @Test func lockoutIsScopedToLibrary() async {
        let rl = UnlockRateLimiter(maxFailures: 2, lockoutSeconds: 30)
        let t0 = Date(timeIntervalSince1970: 1000)
        await rl.recordFailure("L1", principal: "p", now: t0)
        await rl.recordFailure("L1", principal: "p", now: t0)
        #expect(await rl.isLockedOut("L1", principal: "p", now: t0) == true)
        #expect(await rl.isLockedOut("L2", principal: "p", now: t0) == false)
    }

    /// 429 に載せる Retry-After の値（残り秒・切り上げ・最低 1）。
    @Test func retryAfterReportsRemainingSeconds() async {
        let rl = UnlockRateLimiter(maxFailures: 1, lockoutSeconds: 30)
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(await rl.retryAfterSeconds("L", principal: "p", now: t0) == nil)   // 未ロックアウト
        await rl.recordFailure("L", principal: "p", now: t0)
        #expect(await rl.retryAfterSeconds("L", principal: "p", now: t0) == 30)
        #expect(await rl.retryAfterSeconds("L", principal: "p", now: t0.addingTimeInterval(29.5)) == 1)
        #expect(await rl.retryAfterSeconds("L", principal: "p", now: t0.addingTimeInterval(31)) == nil)
        #expect(await rl.retryAfterSeconds("L", principal: "other", now: t0) == nil)
    }

    /// 成功はその principal のカウンタだけを消す。
    @Test func successClearsOnlyThatPrincipal() async {
        let rl = UnlockRateLimiter(maxFailures: 2, lockoutSeconds: 30)
        let t0 = Date(timeIntervalSince1970: 1000)
        await rl.recordFailure("L", principal: "a", now: t0)
        await rl.recordFailure("L", principal: "b", now: t0)
        await rl.recordSuccess("L", principal: "a")
        await rl.recordFailure("L", principal: "b", now: t0)   // b は 2 回目 → 閾値到達
        #expect(await rl.isLockedOut("L", principal: "b", now: t0) == true)
        #expect(await rl.isLockedOut("L", principal: "a", now: t0) == false)
    }

    /// #2: 連続失敗が閾値（既定 5）を超えると unlock が 429 で拒否される（正しいパスワードでも拒否）。
    @Test func repeatedWrongPasswordEventuallyRateLimited() async throws {
        let (fixture, app, uuid) = try makeLockedFixtureApp()
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            for _ in 0..<5 {   // 既定 maxFailures=5：5 回まで 403
                try await client.execute(
                    uri: "/api/v1/libraries/\(uuid)/unlock", method: .post,
                    headers: [.authorization: "Bearer tk"],
                    body: .init(string: #"{"password":"nope"}"#)
                ) { #expect($0.status == .forbidden) }
            }
            // 6 回目はロックアウト → 429
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/unlock", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"password":"nope"}"#)
            ) { #expect($0.status == .tooManyRequests) }
            // ロックアウト中は正しいパスワードでも 429（ブルートフォース抑止）
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/unlock", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"password":"pw123"}"#)
            ) { #expect($0.status == .tooManyRequests) }
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
