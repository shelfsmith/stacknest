// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

@Suite("Grant scope")
struct GrantScopeTests {
    private func makeApp(grants: [Grant], libs: [ServedLibrary]) -> some ApplicationProtocol {
        LibraryServerCore(config: .init(port: 0, token: "unused", editToken: nil, grantsProvider: { grants }),
                          dataSource: StaticLibraryDataSource(libraries: libs)).buildApplication()
    }
    @Test func scopeLimitsLibrariesAnd404() async throws {
        let fa = try TestLibraryFixture(name: "A", bookCount: 1); defer { fa.cleanup() }
        let fb = try TestLibraryFixture(name: "B", bookCount: 1); defer { fb.cleanup() }
        let a = fa.servedLibrary(); let b = fb.servedLibrary()
        let g = Grant(id: "g", label: "fam", token: "FAM", tier: .read,
                      scope: .libraries([a.uuid]), createdAt: Date(timeIntervalSince1970: 0))
        try await makeApp(grants: [g], libs: [a, b]).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries", method: .get, headers: [.authorization: "Bearer FAM"]) { r in
                let dto = try JSONDecoder().decode([LibraryDTO].self, from: r.body)
                #expect(dto.count == 1); #expect(dto.first?.id == a.uuid)
            }
            try await client.execute(uri: "/api/v1/libraries/\(b.uuid)/books", method: .get, headers: [.authorization: "Bearer FAM"]) { r in
                #expect(r.status == .notFound)
            }
            try await client.execute(uri: "/api/v1/libraries/\(a.uuid)/books", method: .get, headers: [.authorization: "Bearer FAM"]) { r in
                #expect(r.status == .ok)
            }
        }
    }
    @Test func unknownTokenUnauthorized() async throws {
        let fa = try TestLibraryFixture(name: "A2", bookCount: 1); defer { fa.cleanup() }
        try await makeApp(grants: [], libs: [fa.servedLibrary()]).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries", method: .get, headers: [.authorization: "Bearer X"]) { r in
                #expect(r.status == .unauthorized)
            }
        }
    }
}
