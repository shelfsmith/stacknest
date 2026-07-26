// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import AppCore
@testable import LibraryServer

/// G23 (m4): grant の read/write を単一のリポジトリへ通す。
///
/// 従来は read が `grantsProvider`、write が `GrantStore(UserDefaults.standard)` 直接という
/// 非対称で、テストは固定配列を read させつつ write は実 UserDefaults へ飛んでいたため
/// **CRUD が永続化に反映されたかを検証できなかった**。
@Suite("GrantRepository")
struct GrantRepositoryTests {

    private func admin() -> Grant {
        Grant(id: "adm", label: "admin", token: "ADM", tier: .admin, scope: .all,
              createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - リポジトリ単体

    @Test func inMemoryUpsertThenAll() {
        let repo = InMemoryGrantRepository(initial: [])
        repo.upsert(Grant(id: "g1", label: "t", token: "T", tier: .read, scope: .all,
                          createdAt: Date(timeIntervalSince1970: 0)))
        #expect(repo.all().count == 1)
        #expect(repo.all().first?.token == "T")
    }

    @Test func inMemoryDeleteRemoves() {
        let g = Grant(id: "g1", label: "t", token: "T", tier: .read, scope: .all,
                      createdAt: Date(timeIntervalSince1970: 0))
        let repo = InMemoryGrantRepository(initial: [g])
        repo.delete(id: "g1")
        #expect(repo.all().isEmpty)
    }

    /// 同じ id の upsert は置換であり重複させない。
    @Test func upsertReplacesSameID() {
        let repo = InMemoryGrantRepository(initial: [
            Grant(id: "g1", label: "old", token: "T", tier: .read, scope: .all,
                  createdAt: Date(timeIntervalSince1970: 0))
        ])
        repo.upsert(Grant(id: "g1", label: "new", token: "T2", tier: .edit, scope: .all,
                          createdAt: Date(timeIntervalSince1970: 0)))
        #expect(repo.all().count == 1)
        #expect(repo.all().first?.label == "new")
        #expect(repo.all().first?.tier == .edit)
    }

    // MARK: - m4 の要: CRUD が永続化に反映されることを検証できる

    @Test func postGrantIsPersistedThroughRepository() async throws {
        let f = try TestLibraryFixture(name: "GR1", bookCount: 1); defer { f.cleanup() }
        let repo = InMemoryGrantRepository(initial: [admin()])
        let app = LibraryServerCore(
            config: .init(port: 0, token: "u", editToken: nil, grantRepository: repo),
            dataSource: StaticLibraryDataSource(libraries: [f.servedLibrary()])).buildApplication()
        try await app.test(.router) { client in
            let body = #"{"label":"家族","tier":"read","scope":{"libraries":["\#(f.servedLibrary().uuid)"]}}"#
            try await client.execute(uri: "/api/v1/grants", method: .post,
                                     headers: [.authorization: "Bearer ADM", .contentType: "application/json"],
                                     body: ByteBuffer(string: body)) { r in
                #expect(r.status == .ok)
            }
        }
        // 従来は検証できなかった箇所: 書き込みが同じリポジトリに現れる。
        #expect(repo.all().count == 2)
        #expect(repo.all().contains { $0.label == "家族" })
    }

    @Test func deleteGrantIsPersistedThroughRepository() async throws {
        let f = try TestLibraryFixture(name: "GR2", bookCount: 1); defer { f.cleanup() }
        let victim = Grant(id: "vic", label: "消される", token: "VIC", tier: .read, scope: .all,
                           createdAt: Date(timeIntervalSince1970: 0))
        let repo = InMemoryGrantRepository(initial: [admin(), victim])
        let app = LibraryServerCore(
            config: .init(port: 0, token: "u", editToken: nil, grantRepository: repo),
            dataSource: StaticLibraryDataSource(libraries: [f.servedLibrary()])).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/grants/vic", method: .delete,
                                     headers: [.authorization: "Bearer ADM"]) { r in
                #expect(r.status == .ok || r.status == .noContent)
            }
        }
        #expect(repo.all().contains { $0.id == "vic" } == false)
        #expect(repo.all().count == 1)
    }

    /// G23 Codex Medium #5 の回帰: `grantsProvider` と `grantRepository` を**両方**指定しても
    /// split-brain にならない（repository を唯一の源とし、provider は無視される）。
    /// 以前は read が provider・write が repository に分かれ、CRUD が 200 を返しても
    /// 認証や GET に反映されなかった。
    @Test func repositoryWinsWhenBothProviderAndRepositoryAreSet() async throws {
        let f = try TestLibraryFixture(name: "GR4", bookCount: 1); defer { f.cleanup() }
        let repo = InMemoryGrantRepository(initial: [admin()])
        // provider には repository に無い別トークンだけを載せる（採用されたら認証が食い違う）。
        let stale = Grant(id: "stale", label: "stale", token: "STALE", tier: .admin, scope: .all,
                          createdAt: Date(timeIntervalSince1970: 0))
        let app = LibraryServerCore(
            config: .init(port: 0, token: "u", editToken: nil,
                          grantsProvider: { [stale] }, grantRepository: repo),
            dataSource: StaticLibraryDataSource(libraries: [f.servedLibrary()])).buildApplication()
        try await app.test(.router) { client in
            // repository 側のトークンで通る。
            try await client.execute(uri: "/api/v1/grants", method: .get,
                                     headers: [.authorization: "Bearer ADM"]) { r in
                #expect(r.status == .ok)
            }
            // provider 側にしかないトークンは通らない（provider は無視されている）。
            try await client.execute(uri: "/api/v1/grants", method: .get,
                                     headers: [.authorization: "Bearer STALE"]) { r in
                #expect(r.status == .unauthorized)
            }
            // 書き込みも repository へ届く。
            let body = #"{"label":"新規","tier":"read","scope":{"libraries":["\#(f.servedLibrary().uuid)"]}}"#
            try await client.execute(uri: "/api/v1/grants", method: .post,
                                     headers: [.authorization: "Bearer ADM", .contentType: "application/json"],
                                     body: ByteBuffer(string: body)) { r in
                #expect(r.status == .ok)
            }
        }
        #expect(repo.all().count == 2)
        #expect(repo.all().contains { $0.label == "新規" })
    }

    /// repository を注入した場合は認証もそこから読む（read と write が同じ源）。
    @Test func authenticationReadsFromRepository() async throws {
        let f = try TestLibraryFixture(name: "GR3", bookCount: 1); defer { f.cleanup() }
        let repo = InMemoryGrantRepository(initial: [admin()])
        let app = LibraryServerCore(
            config: .init(port: 0, token: "u", editToken: nil, grantRepository: repo),
            dataSource: StaticLibraryDataSource(libraries: [f.servedLibrary()])).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/grants", method: .get,
                                     headers: [.authorization: "Bearer ADM"]) { r in
                #expect(r.status == .ok)
            }
            // リポジトリに無いトークンは 401。
            try await client.execute(uri: "/api/v1/grants", method: .get,
                                     headers: [.authorization: "Bearer NOPE"]) { r in
                #expect(r.status == .unauthorized)
            }
        }
    }
}
