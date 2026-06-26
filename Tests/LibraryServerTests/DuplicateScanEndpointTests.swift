// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer

@Suite("POST /duplicates/scan endpoint")
struct DuplicateScanEndpointTests {
    // MARK: - helpers

    private func makeApp(fixture: TestLibraryFixture, adminTier: Bool = false) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    /// 1x1 ピクセルの PNG データ（base64 decode 済み）。AddBooksEndpointTests と同一バイト列。
    private func minimalPNG() -> Data {
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        return Data(base64Encoded: b64)!
    }

    private func writeTempPNG(suffix: String = "") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-dup-\(UUID().uuidString)\(suffix).png")
        try minimalPNG().write(to: url)
        return url
    }

    // MARK: - 重複スキャン正常系

    /// 同一内容の 2 ファイルをライブラリに追加してスキャンし、
    /// exact グループが 1 件・メンバーが 2 件であることを確認する。
    @Test func scanDetectsExactDuplicates() async throws {
        let fixture = try TestLibraryFixture(name: "DupScan", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture, adminTier: true)

        // 同一内容 (minimalPNG) の 2 ファイルを異なるパスに生成
        let urlA = try writeTempPNG(suffix: "-a")
        let urlB = try writeTempPNG(suffix: "-b")
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try await app.test(.router) { client in
            // 両ファイルをライブラリに追加 (POST /books)
            let addBody = try JSONEncoder().encode(AddBooksRequestDTO(paths: [urlA.path, urlB.path]))
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(addBody))
            ) { response in
                #expect(response.status == .ok)
            }

            // POST /duplicates/scan (W トークン)
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/duplicates/scan",
                method: .post,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let reply = try decoder.decode(DuplicateScanReply.self, from: Data(buffer: response.body))
                #expect(reply.exact.count == 1)
                #expect(reply.exact.first?.members.count == 2)
                #expect(reply.hashedCount >= 2)
            }
        }
    }

    // MARK: - 権限制限

    /// R トークンでスキャン → 403。
    @Test func scanWithReadTokenForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "DupScanForbidden", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/duplicates/scan",
                method: .post,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }
}
