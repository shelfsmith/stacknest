// SPDX-License-Identifier: MIT
import Testing
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("LibraryServer spike")
struct ServerSpikeTests {
    /// /api/v1/server/info が capability JSON を返す（認証はまだ無し — Task 2 で追加）。
    @Test func serverInfoRespondsWithCapabilities() async throws {
        let server = LibraryServerCore(
            config: .init(port: 0, token: "test-token"),
            dataSource: StaticLibraryDataSource(libraries: [])
        )
        let app = server.buildApplication()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/server/info", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"fileOps\""))
                #expect(body.contains("\"version\""))
            }
        }
    }

    /// 実ポート起動・停止のスパイク（アプリ内蔵の成立性確認）。
    @Test func liveServerStartsAndStops() async throws {
        let server = LibraryServerCore(
            config: .init(port: 0, token: "t"),
            dataSource: StaticLibraryDataSource(libraries: [])
        )
        let app = server.buildApplication()
        try await app.test(.live) { client in
            try await client.execute(uri: "/api/v1/server/info", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
