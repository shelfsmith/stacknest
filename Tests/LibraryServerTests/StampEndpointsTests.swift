// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer

@Suite("stamp-definitions GET/PUT ＋ books/stamp POST endpoints")
struct StampEndpointsTests {
    private func decodeDefs(_ buffer: ByteBuffer) throws -> [String: [String]] {
        try JSONDecoder().decode(StampDefinitionsDTO.self, from: Data(buffer: buffer)).definitions
    }
    private func decodeReply(_ buffer: ByteBuffer) throws -> StampApplyReply {
        try JSONDecoder().decode(StampApplyReply.self, from: Data(buffer: buffer))
    }
    private func makeApp(_ lib: ServedLibrary, editToken: String? = "W") -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: editToken),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
    }

    /// 定義 GET 既定空 → PUT(W) で保存 → GET(R) で往復一致。未知キーは除外。
    @Test func putThenGetRoundTripFiltersUnknownKeys() async throws {
        let fixture = try TestLibraryFixture(name: "Stamp1", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            // 既定は空
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/stamp-definitions",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let defs = try decodeDefs(response.body)
                #expect(defs.isEmpty)
            }
            // PUT(W)：genre と未知キー title を送る
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/stamp-definitions",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(string: #"{"definitions":{"genre":["少年","SF"],"title":["x"]}}"#)
            ) { response in
                #expect(response.status == .ok)
                let defs = try decodeDefs(response.body)
                #expect(defs["genre"] == ["少年", "SF"])
                #expect(defs["title"] == nil)   // 未知キーは除外
            }
            // GET(R) で往復一致
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/stamp-definitions",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { response in
                let defs = try decodeDefs(response.body)
                #expect(defs["genre"] == ["少年", "SF"])
            }
        }
    }

    /// PUT は RW 専用：R トークンは 403。
    @Test func putWithReadTokenForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "Stamp2", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/stamp-definitions",
                method: .put,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(string: #"{"definitions":{"genre":["x"]}}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// 一括スタンプ適用(W)：append が DB に反映。R は 403。不正 field は 400。
    @Test func applyStampAppendsAndGates() async throws {
        let fixture = try TestLibraryFixture(name: "Stamp3", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            // W で genre に "少年" を append
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/stamp",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(string: #"{"field":"genre","value":"少年","bookIDs":[1]}"#)
            ) { response in
                #expect(response.status == .ok)
                let reply = try decodeReply(response.body)
                #expect(reply.updated == 1)
            }
            // R は 403
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/stamp",
                method: .post,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(string: #"{"field":"genre","value":"x","bookIDs":[1]}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
            // 不正 field は 400
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/stamp",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(string: #"{"field":"title","value":"x","bookIDs":[1]}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
        // DB に append 反映
        let row = try fixture.db.fetchBook(id: 1)
        #expect(row?.genre == "少年")
    }
}
