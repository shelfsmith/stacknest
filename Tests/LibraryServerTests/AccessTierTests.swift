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
}
