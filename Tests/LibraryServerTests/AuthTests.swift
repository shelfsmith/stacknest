// SPDX-License-Identifier: MIT
import Testing
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("Auth")
struct AuthTests {
    private func makeApp() -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "secret-token"),
            dataSource: StaticLibraryDataSource(libraries: [])
        ).buildApplication()
    }

    @Test func rejectsMissingToken() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func rejectsWrongToken() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries", method: .get,
                headers: [.authorization: "Bearer wrong"]
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func acceptsCorrectToken() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries", method: .get,
                headers: [.authorization: "Bearer secret-token"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// /server/info は認証不要（ペアリング前の到達性確認用）。
    @Test func serverInfoIsPublic() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/api/v1/server/info", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// /libraries はデータソースの内容を JSON 配列で返す。
    @Test func librariesListsServedLibraries() async throws {
        let fixture = try TestLibraryFixture(name: "棚A", bookCount: 2)
        defer { fixture.cleanup() }
        let app = LibraryServerCore(
            config: .init(port: 0, token: "secret-token"),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries", method: .get,
                headers: [.authorization: "Bearer secret-token"]
            ) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"棚A\""))
                #expect(body.contains("\"bookCount\":2"))
            }
        }
    }
}
