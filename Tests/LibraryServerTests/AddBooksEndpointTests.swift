// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer

@Suite("POST /books endpoint")
struct AddBooksEndpointTests {
    // MARK: - helpers

    private func makeApp(fixture: TestLibraryFixture, editToken: String? = "W") -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: editToken),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    /// 1x1 ピクセルの PNG データ（base64 decode 済み）。
    private func minimalPNG() -> Data {
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        return Data(base64Encoded: b64)!
    }

    private func writeTempPNG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-add-\(UUID().uuidString).png")
        try minimalPNG().write(to: url)
        return url
    }

    private func decodeReply(_ buffer: ByteBuffer) throws -> AddBooksReplyDTO {
        try JSONDecoder().decode(AddBooksReplyDTO.self, from: Data(buffer: buffer))
    }

    // MARK: - 権限制限

    /// R トークンで POST /books → 403。
    @Test func addWithReadTokenForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "AddForbidden", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books",
                method: .post,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(string: #"{"paths":[]}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    // MARK: - 正常系

    /// RW トークンで庫外の一時 PNG を追加 → 200＋addedIDs.count == 1。
    @Test func addPNGWithWriteToken() async throws {
        let fixture = try TestLibraryFixture(name: "AddOK", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let pngURL = try writeTempPNG()
        defer { try? FileManager.default.removeItem(at: pngURL) }

        try await app.test(.router) { client in
            let body = try JSONEncoder().encode(AddBooksRequestDTO(paths: [pngURL.path]))
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { response in
                #expect(response.status == .ok)
                let reply = try decodeReply(response.body)
                #expect(reply.addedIDs.count == 1)
                #expect(reply.alreadyPresent.isEmpty)
                #expect(reply.failed.isEmpty)
            }
        }
    }

    // MARK: - 重複追加

    /// 同一パスを2回 POST → 1回目は addedIDs.count==1、2回目は addedIDs が空で alreadyPresent にパスが入る。
    @Test func addSamePathTwiceReturnsAlreadyPresent() async throws {
        let fixture = try TestLibraryFixture(name: "AddDup", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let pngURL = try writeTempPNG()
        defer { try? FileManager.default.removeItem(at: pngURL) }

        try await app.test(.router) { client in
            let body = try JSONEncoder().encode(AddBooksRequestDTO(paths: [pngURL.path]))

            // 1回目 → 追加成功
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { response in
                #expect(response.status == .ok)
                let reply = try decodeReply(response.body)
                #expect(reply.addedIDs.count == 1)
                #expect(reply.alreadyPresent.isEmpty)
            }

            // 2回目 → alreadyPresent に同パスが入り、addedIDs は空
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { response in
                #expect(response.status == .ok)
                let reply = try decodeReply(response.body)
                #expect(reply.addedIDs.isEmpty)
                #expect(reply.alreadyPresent.contains(pngURL.path))
            }
        }
    }
}
