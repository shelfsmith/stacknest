// SPDX-License-Identifier: MIT
import Testing
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("Docs endpoints")
struct DocsEndpointTests {

    // MARK: - helpers

    private func makeApp(apiOnly: Bool) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "tk", apiOnly: apiOnly),
            dataSource: StaticLibraryDataSource(libraries: [])
        ).buildApplication()
    }

    // MARK: - 共通: apiOnly=false（既定）構成

    /// ① GET /openapi.yaml は無トークンで 200、本文に openapi: 3.1 を含む。
    @Test func openapiYamlIsAccessibleWithoutAuth() async throws {
        try await makeApp(apiOnly: false).test(.router) { client in
            try await client.execute(uri: "/openapi.yaml", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("openapi: 3.1"))
            }
        }
    }

    /// ② GET /docs は無トークンで 200、本文に redoc を含む。
    @Test func docsEndpointIsAccessibleWithoutAuth() async throws {
        try await makeApp(apiOnly: false).test(.router) { client in
            try await client.execute(uri: "/docs", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).lowercased().contains("redoc"))
            }
        }
    }

    /// ③ GET /api/v1/libraries は無トークンで 401（データ API はトークン必須）。
    @Test func dataAPIRequiresAuthWhenApiOnlyFalse() async throws {
        try await makeApp(apiOnly: false).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    // MARK: - apiOnly=true 構成

    /// ④ apiOnly=true では GET / が 200 を返し、本文に redoc を含む。
    @Test func rootServesRedocWhenApiOnly() async throws {
        try await makeApp(apiOnly: true).test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).lowercased().contains("redoc"))
            }
        }
    }

    /// ④b apiOnly=true でもデータ API は 401 のまま（認証が外れていないこと）。
    @Test func dataAPIRequiresAuthWhenApiOnlyTrue() async throws {
        try await makeApp(apiOnly: true).test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    // MARK: - apiOnly=false 構成: / は Web UI を返す

    /// ⑤ apiOnly=false では GET / が Web UI（index.html）を返す。
    @Test func rootServesWebUIWhenApiOnlyFalse() async throws {
        try await makeApp(apiOnly: false).test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body).lowercased()
                // FileMiddleware が index.html を返す。
                #expect(body.contains("<!doctype html") || body.contains("<html"))
            }
        }
    }
}
