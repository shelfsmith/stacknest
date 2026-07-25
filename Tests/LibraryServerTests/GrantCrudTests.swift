// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

@Suite("Grant CRUD")
struct GrantCrudTests {
    private func makeApp(_ grants: [Grant], _ lib: ServedLibrary) -> some ApplicationProtocol {
        LibraryServerCore(config: .init(port: 0, token: "u", editToken: nil, grantsProvider: { grants }),
                          dataSource: StaticLibraryDataSource(libraries: [lib])).buildApplication()
    }
    private func makeApp(_ grants: [Grant], _ libs: [ServedLibrary]) -> some ApplicationProtocol {
        LibraryServerCore(config: .init(port: 0, token: "u", editToken: nil, grantsProvider: { grants }),
                          dataSource: StaticLibraryDataSource(libraries: libs)).buildApplication()
    }
    private func admin() -> Grant { Grant(id: "adm", label: "admin", token: "ADM", tier: .admin, scope: .all, createdAt: Date(timeIntervalSince1970: 0)) }

    @Test func adminCreatesGrant() async throws {
        let f = try TestLibraryFixture(name: "GC1", bookCount: 1); defer { f.cleanup() }
        let lib = f.servedLibrary()
        try await makeApp([admin()], lib).test(.router) { client in
            let body = #"{"label":"家族","tier":"read","scope":{"libraries":["\#(lib.uuid)"]}}"#
            try await client.execute(uri: "/api/v1/grants", method: .post,
                headers: [.authorization: "Bearer ADM", .contentType: "application/json"], body: ByteBuffer(string: body)) { r in
                #expect(r.status == .ok)
                let dto = try JSONDecoder().decode(GrantDTO.self, from: r.body)
                #expect(dto.label == "家族"); #expect(!dto.token.isEmpty); #expect(dto.tier == .read)
            }
        }
    }
    @Test func nonAdminForbidden() async throws {
        let f = try TestLibraryFixture(name: "GC2", bookCount: 1); defer { f.cleanup() }
        let reader = Grant(id: "r", label: "r", token: "RD", tier: .read, scope: .all, createdAt: Date(timeIntervalSince1970: 0))
        try await makeApp([reader], f.servedLibrary()).test(.router) { client in
            try await client.execute(uri: "/api/v1/grants", method: .get, headers: [.authorization: "Bearer RD"]) { r in
                #expect(r.status == .forbidden)
            }
        }
    }
    @Test func meReturnsScope() async throws {
        let f = try TestLibraryFixture(name: "GC3", bookCount: 1); defer { f.cleanup() }
        let lib = f.servedLibrary()
        let g = Grant(id: "s", label: "s", token: "SC", tier: .read, scope: .libraries([lib.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        try await makeApp([g], lib).test(.router) { client in
            try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer SC"]) { r in
                let me = try JSONDecoder().decode(MeReply.self, from: r.body)
                #expect(me.scope == .libraries([lib.uuid])); #expect(me.tier == .read)
            }
        }
    }

    // MARK: - #3: grants 一覧/PATCH/DELETE の scope フィルタ

    @Test func scopedAdminListsOnlyGrantsWithinItsScope() async throws {
        let fa = try TestLibraryFixture(name: "GA", bookCount: 1); defer { fa.cleanup() }
        let fb = try TestLibraryFixture(name: "GB", bookCount: 1); defer { fb.cleanup() }
        let a = fa.servedLibrary(); let b = fb.servedLibrary()
        let adminA = Grant(id: "admA", label: "adminA", token: "ADMA", tier: .admin,
                           scope: .libraries([a.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        let grantB = Grant(id: "gB", label: "b-token", token: "TOKB", tier: .read,
                           scope: .libraries([b.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        try await makeApp([adminA, grantB], [a, b]).test(.router) { client in
            try await client.execute(uri: "/api/v1/grants", method: .get, headers: [.authorization: "Bearer ADMA"]) { r in
                #expect(r.status == .ok)
                let dtos = try JSONDecoder().decode([GrantDTO].self, from: r.body)
                #expect(dtos.map(\.id) == ["admA"])
                #expect(!dtos.contains { $0.token == "TOKB" })   // 他ライブラリの token を漏らさない
            }
        }
    }

    @Test func globalAdminListsAllGrants() async throws {
        let fa = try TestLibraryFixture(name: "GA2", bookCount: 1); defer { fa.cleanup() }
        let fb = try TestLibraryFixture(name: "GB2", bookCount: 1); defer { fb.cleanup() }
        let a = fa.servedLibrary(); let b = fb.servedLibrary()
        let grantB = Grant(id: "gB2", label: "b-token", token: "TOKB2", tier: .read,
                           scope: .libraries([b.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        try await makeApp([admin(), grantB], [a, b]).test(.router) { client in
            try await client.execute(uri: "/api/v1/grants", method: .get, headers: [.authorization: "Bearer ADM"]) { r in
                #expect(r.status == .ok)
                let dtos = try JSONDecoder().decode([GrantDTO].self, from: r.body)
                #expect(Set(dtos.map(\.id)) == ["adm", "gB2"])
            }
        }
    }

    @Test func scopedAdminPatchDeleteOutOfScopeGrantIs404() async throws {
        let fa = try TestLibraryFixture(name: "GA3", bookCount: 1); defer { fa.cleanup() }
        let fb = try TestLibraryFixture(name: "GB3", bookCount: 1); defer { fb.cleanup() }
        let a = fa.servedLibrary(); let b = fb.servedLibrary()
        let adminA = Grant(id: "admA3", label: "adminA", token: "ADMA3", tier: .admin,
                           scope: .libraries([a.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        let grantB = Grant(id: "gB3", label: "b-token", token: "TOKB3", tier: .read,
                           scope: .libraries([b.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        try await makeApp([adminA, grantB], [a, b]).test(.router) { client in
            try await client.execute(uri: "/api/v1/grants/gB3", method: .patch,
                headers: [.authorization: "Bearer ADMA3", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"label":"pwned"}"#)) { r in
                #expect(r.status == .notFound)
            }
            try await client.execute(uri: "/api/v1/grants/gB3", method: .delete,
                headers: [.authorization: "Bearer ADMA3"]) { r in
                #expect(r.status == .notFound)
            }
        }
    }

    // MARK: - Codex Critical: scope 限定 admin による scope 昇格の禁止
    // 対象 grant の containment（既存テスト）に加え、**作成/更新後の scope** も呼出者の scope に
    // 含まれることを要求する。これが無いと A 限定 admin が `.all` grant を発行して全庫を掌握できる。

    @Test func scopedAdminCannotCreateGlobalScopeGrant() async throws {
        let fa = try TestLibraryFixture(name: "GA5", bookCount: 1); defer { fa.cleanup() }
        let a = fa.servedLibrary()
        let adminA = Grant(id: "admA5", label: "adminA", token: "ADMA5", tier: .admin,
                           scope: .libraries([a.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        try await makeApp([adminA], [a]).test(.router) { client in
            // `.all`（無制限）grant の作成は拒否
            try await client.execute(uri: "/api/v1/grants", method: .post,
                headers: [.authorization: "Bearer ADMA5", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"label":"pwn","tier":"admin","scope":{"all":{}}}"#)) { r in
                #expect(r.status == .forbidden)
            }
            // 自分の scope 内（A）への作成は従来どおり成功
            try await client.execute(uri: "/api/v1/grants", method: .post,
                headers: [.authorization: "Bearer ADMA5", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"label":"ok","tier":"read","scope":{"libraries":["\#(a.uuid)"]}}"#)) { r in
                #expect(r.status == .ok)
            }
        }
    }

    @Test func scopedAdminCannotCreateGrantForOtherLibrary() async throws {
        let fa = try TestLibraryFixture(name: "GA6", bookCount: 1); defer { fa.cleanup() }
        let fb = try TestLibraryFixture(name: "GB6", bookCount: 1); defer { fb.cleanup() }
        let a = fa.servedLibrary(); let b = fb.servedLibrary()
        let adminA = Grant(id: "admA6", label: "adminA", token: "ADMA6", tier: .admin,
                           scope: .libraries([a.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        try await makeApp([adminA], [a, b]).test(.router) { client in
            try await client.execute(uri: "/api/v1/grants", method: .post,
                headers: [.authorization: "Bearer ADMA6", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"label":"pwn","tier":"admin","scope":{"libraries":["\#(b.uuid)"]}}"#)) { r in
                #expect(r.status == .forbidden)
            }
        }
    }

    @Test func scopedAdminCannotEscalateOwnGrantScopeViaPatch() async throws {
        let fa = try TestLibraryFixture(name: "GA7", bookCount: 1); defer { fa.cleanup() }
        let fb = try TestLibraryFixture(name: "GB7", bookCount: 1); defer { fb.cleanup() }
        let a = fa.servedLibrary(); let b = fb.servedLibrary()
        let adminA = Grant(id: "admA7", label: "adminA", token: "ADMA7", tier: .admin,
                           scope: .libraries([a.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        try await makeApp([adminA], [a, b]).test(.router) { client in
            // 自分の grant を `.all` へ昇格させる PATCH は拒否
            try await client.execute(uri: "/api/v1/grants/admA7", method: .patch,
                headers: [.authorization: "Bearer ADMA7", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"scope":{"all":{}}}"#)) { r in
                #expect(r.status == .forbidden)
            }
            // 他ライブラリ B へ広げる PATCH も拒否
            try await client.execute(uri: "/api/v1/grants/admA7", method: .patch,
                headers: [.authorization: "Bearer ADMA7", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"scope":{"libraries":["\#(b.uuid)"]}}"#)) { r in
                #expect(r.status == .forbidden)
            }
        }
    }

    @Test func globalAdminCanStillCreateAnyScopeGrant() async throws {
        let fa = try TestLibraryFixture(name: "GA8", bookCount: 1); defer { fa.cleanup() }
        let a = fa.servedLibrary()
        try await makeApp([admin()], [a]).test(.router) { client in
            // グローバル admin（scope .all）は従来どおり `.all` grant を作成できる（回帰なし）
            try await client.execute(uri: "/api/v1/grants", method: .post,
                headers: [.authorization: "Bearer ADM", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"label":"global","tier":"read","scope":{"all":{}}}"#)) { r in
                #expect(r.status == .ok)
            }
        }
    }

    @Test func scopedAdminPatchInScopeGrantStillSucceeds() async throws {
        let fa = try TestLibraryFixture(name: "GA4", bookCount: 1); defer { fa.cleanup() }
        let a = fa.servedLibrary()
        let adminA = Grant(id: "admA4", label: "adminA", token: "ADMA4", tier: .admin,
                           scope: .libraries([a.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        try await makeApp([adminA], [a]).test(.router) { client in
            try await client.execute(uri: "/api/v1/grants/admA4", method: .patch,
                headers: [.authorization: "Bearer ADMA4", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"label":"renamed"}"#)) { r in
                #expect(r.status == .ok)
                let dto = try JSONDecoder().decode(GrantDTO.self, from: r.body)
                #expect(dto.label == "renamed")
            }
        }
    }
}
