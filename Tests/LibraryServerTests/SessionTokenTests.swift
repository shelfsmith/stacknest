// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import AppCore
@testable import LibraryServer

/// G23 (#9/#10): URL クエリに載せるトークンを短命なセッショントークンへ置き換える。
///
/// EventSource と `<img>` はカスタムヘッダを送れないため認証情報を URL に置かざるを得ないが、
/// そこに**永続の grant token** が載るとブラウザ履歴やプロキシログに残り続ける。
/// `lt`（ライブラリトークン）は既に TTL 付き・メモリのみで設計されており、grant token だけが
/// その設計から漏れていた。
@Suite("SessionToken")
struct SessionTokenTests {

    private func admin() -> Grant {
        Grant(id: "adm", label: "admin", token: "ADM", tier: .admin, scope: .all,
              createdAt: Date(timeIntervalSince1970: 0))
    }

    private func makeApp(_ grants: [Grant], _ lib: ServedLibrary) -> some ApplicationProtocol {
        LibraryServerCore(config: .init(port: 0, token: "u", editToken: nil, grantsProvider: { grants }),
                          dataSource: StaticLibraryDataSource(libraries: [lib])).buildApplication()
    }

    // MARK: - ストア単体

    @Test func issuedTokenResolvesToGrantToken() async {
        let store = SessionTokenStore(ttl: .seconds(60))
        let s = await store.issue(grantToken: "GRANT")
        #expect(await store.resolve(s) == "GRANT")
    }

    @Test func unknownTokenResolvesToNil() async {
        let store = SessionTokenStore(ttl: .seconds(60))
        #expect(await store.resolve("nope") == nil)
    }

    @Test func expiredTokenIsRejected() async throws {
        let store = SessionTokenStore(ttl: .milliseconds(50))
        let s = await store.issue(grantToken: "GRANT")
        try await Task.sleep(for: .milliseconds(150))
        #expect(await store.resolve(s) == nil)
    }

    @Test func eachIssueReturnsDistinctToken() async {
        let store = SessionTokenStore(ttl: .seconds(60))
        let a = await store.issue(grantToken: "G")
        let b = await store.issue(grantToken: "G")
        #expect(a != b)
    }

    // MARK: - エンドポイントと認証

    @Test func postSessionReturnsTokenForHeaderAuth() async throws {
        let f = try TestLibraryFixture(name: "ST1", bookCount: 1); defer { f.cleanup() }
        try await makeApp([admin()], f.servedLibrary()).test(.router) { client in
            try await client.execute(uri: "/api/v1/session", method: .post,
                                     headers: [.authorization: "Bearer ADM"]) { r in
                #expect(r.status == .ok)
                let dto = try JSONDecoder().decode(SessionReply.self, from: r.body)
                #expect(!dto.sessionToken.isEmpty)
                #expect(dto.sessionToken != "ADM")   // 永続トークンをそのまま返さない
                #expect(dto.expiresIn > 0)
            }
        }
    }

    /// 発行されたセッショントークンは `?token=` クエリで認証に使える（EventSource / img 用）。
    @Test func sessionTokenAuthenticatesViaQuery() async throws {
        let f = try TestLibraryFixture(name: "ST2", bookCount: 1); defer { f.cleanup() }
        try await makeApp([admin()], f.servedLibrary()).test(.router) { client in
            var session = ""
            try await client.execute(uri: "/api/v1/session", method: .post,
                                     headers: [.authorization: "Bearer ADM"]) { r in
                session = try JSONDecoder().decode(SessionReply.self, from: r.body).sessionToken
            }
            try await client.execute(uri: "/api/v1/libraries?token=\(session)", method: .get) { r in
                #expect(r.status == .ok)
            }
        }
    }

    /// 未知のセッショントークンは 401（永続トークンとしても解決できない）。
    @Test func unknownQueryTokenIsUnauthorized() async throws {
        let f = try TestLibraryFixture(name: "ST3", bookCount: 1); defer { f.cleanup() }
        try await makeApp([admin()], f.servedLibrary()).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries?token=bogus-session", method: .get) { r in
                #expect(r.status == .unauthorized)
            }
        }
    }

    /// 後方互換: 既存クライアントが永続トークンを直接クエリに載せても通る。
    @Test func legacyGrantTokenInQueryStillWorks() async throws {
        let f = try TestLibraryFixture(name: "ST4", bookCount: 1); defer { f.cleanup() }
        try await makeApp([admin()], f.servedLibrary()).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries?token=ADM", method: .get) { r in
                #expect(r.status == .ok)
            }
        }
    }

    /// セッションの発行自体はヘッダ認証を要求する（クエリ経由での発行は受け付けない）。
    @Test func postSessionRejectsQueryOnlyAuth() async throws {
        let f = try TestLibraryFixture(name: "ST5", bookCount: 1); defer { f.cleanup() }
        try await makeApp([admin()], f.servedLibrary()).test(.router) { client in
            try await client.execute(uri: "/api/v1/session?token=ADM", method: .post) { r in
                #expect(r.status == .unauthorized)
            }
        }
    }
}
