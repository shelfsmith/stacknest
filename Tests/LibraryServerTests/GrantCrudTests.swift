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
}
