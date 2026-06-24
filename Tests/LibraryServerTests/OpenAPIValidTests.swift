// SPDX-License-Identifier: MIT
import Testing
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("OpenAPI spec")
struct OpenAPIValidTests {
    private func makeApp() -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [])
        ).buildApplication()
    }

    /// openapi.yaml がバンドルに含まれ、HTTP 経由（認証なし）で取得できること。
    @Test func specBundledAndWellFormed() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/openapi.yaml", method: .get) { response in
                #expect(response.status == .ok)
                let text = String(buffer: response.body)
                #expect(text.contains("openapi: 3.1"))
                #expect(text.contains("/libraries"))
                #expect(text.contains("bearerAuth"))
            }
        }
    }

    /// Redoc docs がバンドルに含まれ、HTTP 経由（認証なし）で取得できること（4.2f: /docs.html → /docs）。
    @Test func redocAssetBundled() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/docs", method: .get) { response in
                #expect(response.status == .ok)
                let text = String(buffer: response.body)
                #expect(text.lowercased().contains("redoc"))
            }
        }
    }
}
