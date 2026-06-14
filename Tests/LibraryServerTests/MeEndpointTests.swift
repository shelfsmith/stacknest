// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer

@Suite("Me / Role-aware auth")
struct MeEndpointTests {
    private func makeApp() -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [])
        ).buildApplication()
    }

    private func decodeMe(_ buffer: ByteBuffer) throws -> MeReply {
        try JSONDecoder().decode(MeReply.self, from: Data(buffer: buffer))
    }

    /// R トークンは read ロールを返す。
    @Test func meReturnsReadForReadToken() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(
                uri: "/api/v1/me", method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let me = try decodeMe(response.body)
                #expect(me.role == .read)
            }
        }
    }

    /// RW（編集）トークンは write ロールを返す。
    @Test func meReturnsWriteForEditToken() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(
                uri: "/api/v1/me", method: .get,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
                let me = try decodeMe(response.body)
                #expect(me.role == .write)
            }
        }
    }

    /// 未知のトークンは 401。
    @Test func meRejectsUnknownToken() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(
                uri: "/api/v1/me", method: .get,
                headers: [.authorization: "Bearer X"]
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
