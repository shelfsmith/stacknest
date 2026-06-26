// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer

@Suite("GET/PUT /watch-config endpoint")
struct WatchConfigEndpointTests {

    private func makeApp(fixture: TestLibraryFixture) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    /// GET on empty lib returns enabled=false, folders=[].
    @Test func getDefaultReturnsDisabledEmpty() async throws {
        let fixture = try TestLibraryFixture(name: "WCDefault", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(buffer: response.body))
                #expect(dto.enabled == false)
                #expect(dto.folders.isEmpty)
            }
        }
    }

    /// PUT → GET roundtrip: enabled=true + one folder.
    @Test func putThenGetRoundtrip() async throws {
        let fixture = try TestLibraryFixture(name: "WCRoundtrip", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let folder = WatchedFolderDTO(id: "abc", path: "/tmp/manga", enabled: true)
        let putBody = WatchConfigDTO(enabled: true, folders: [folder])
        let bodyData = try JSONEncoder().encode(putBody)
        try await app.test(.router) { client in
            // PUT
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .ok)
            }
            // GET
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(buffer: response.body))
                #expect(dto.enabled == true)
                #expect(dto.folders.count == 1)
                #expect(dto.folders[0].path == "/tmp/manga")
            }
        }
    }

    /// PUT with read token → 403.
    @Test func putWithReadTokenForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "WCForbidden", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let bodyData = try JSONEncoder().encode(WatchConfigDTO(enabled: false, folders: []))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/watch-config",
                method: .put,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(bytes: Array(bodyData))
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }
}
