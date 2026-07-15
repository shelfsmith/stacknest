// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
@testable import LibraryServer

@Suite("Access tiers")
struct AccessTierTests {
    private func makeApp(admin: Bool, _ f: TestLibraryFixture) -> some ApplicationProtocol {
        LibraryServerCore(config: .init(port: 0, token: "R", editToken: "W", adminTier: admin),
                          dataSource: StaticLibraryDataSource(libraries: [f.servedLibrary()])).buildApplication()
    }
    @Test func meReturnsTierAndRole() async throws {
        let f = try TestLibraryFixture(name: "TierMe", bookCount: 1); defer { f.cleanup() }
        try await makeApp(admin: false, f).test(.router) { client in
            try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer W"]) { r in
                let me = try JSONDecoder().decode(MeReply.self, from: r.body)
                #expect(me.tier == .edit); #expect(me.role == .write)
            }
            try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer R"]) { r in
                let me = try JSONDecoder().decode(MeReply.self, from: r.body)
                #expect(me.tier == .read); #expect(me.role == .read)
            }
        }
        try await makeApp(admin: true, f).test(.router) { client in
            try await client.execute(uri: "/api/v1/me", method: .get, headers: [.authorization: "Bearer W"]) { r in
                let me = try JSONDecoder().decode(MeReply.self, from: r.body)
                #expect(me.tier == .admin); #expect(me.role == .write)
            }
        }
    }
    @Test func accessTierOrdering() {
        #expect(AccessTier.read < AccessTier.edit)
        #expect(AccessTier.edit < AccessTier.admin)
    }
    @Test func networkEditCannotDoAdminOps() async throws {
        let f = try TestLibraryFixture(name: "TierGate", bookCount: 1); defer { f.cleanup() }
        let lib = f.servedLibrary()
        try await makeApp(admin: false, f).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"password":"x"}"#)) { r in #expect(r.status == .forbidden) }
            try await client.execute(uri: "/api/v1/import-config", method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"autoClassifyEnabled":true,"thickBookThreshold":20}"#)) { r in #expect(r.status == .forbidden) }
            // G12b-3a: watch-config PUT は admin 専用へ再分類（file operations + data/root settings）。
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/watch-config", method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"enabled":false,"folders":[]}"#)) { r in #expect(r.status == .forbidden) }
        }
    }
    @Test func adminEndpointAllowsAdminOps() async throws {
        let f = try TestLibraryFixture(name: "TierAdmin", bookCount: 1); defer { f.cleanup() }
        let lib = f.servedLibrary()
        try await makeApp(admin: true, f).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/lock", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"password":"x"}"#)) { r in #expect(r.status == .noContent) }
            // G12b-3a: watch-config PUT は admin トークンで成功する。
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/watch-config", method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"enabled":false,"folders":[]}"#)) { r in #expect(r.status == .ok) }
        }
    }
    @Test func deleteTrashRequiresAdmin() async throws {
        let f = try TestLibraryFixture(name: "TierTrash", bookCount: 1); defer { f.cleanup() }
        let lib = f.servedLibrary()
        try await makeApp(admin: false, f).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/1?trash=true", method: .delete,
                headers: [.authorization: "Bearer W"]) { r in #expect(r.status == .forbidden) }
        }
        let f2 = try TestLibraryFixture(name: "TierDBdel", bookCount: 1); defer { f2.cleanup() }
        let lib2 = f2.servedLibrary()
        try await makeApp(admin: false, f2).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib2.uuid)/books/1", method: .delete,
                headers: [.authorization: "Bearer W"]) { r in #expect(r.status == .noContent) }
        }
    }
}
