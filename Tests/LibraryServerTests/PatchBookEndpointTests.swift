// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer

@Suite("PATCH /books/:id endpoint")
struct PatchBookEndpointTests {
    // MARK: - helpers

    /// R=read token, W=write(edit) token のサーバを返す。
    private func makeApp(fixture: TestLibraryFixture, editToken: String? = "W") -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: editToken),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    private func decodeDetail(_ buffer: ByteBuffer) throws -> BookDetailDTO {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookDetailDTO.self, from: Data(buffer: buffer))
    }

    // MARK: - 正常系

    /// W トークンで PATCH → 200、タイトルが更新され、後続の GET /detail でも反映される。
    @Test func patchWithWriteTokenUpdatesTitle() async throws {
        let fixture = try TestLibraryFixture(name: "Patch1", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            // PATCH でタイトル更新
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1",
                method: .patch,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(string: #"{"title":"NEW","clearSeries":false,"clearVolume":false,"clearPageDirection":false}"#)
            ) { response in
                #expect(response.status == .ok)
                let detail = try decodeDetail(response.body)
                #expect(detail.title == "NEW")
            }
            // 後続 GET /detail でも反映を確認
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/detail",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let detail = try decodeDetail(response.body)
                #expect(detail.title == "NEW")
            }
        }
    }

    // MARK: - 権限制限

    /// R トークンで PATCH → 403、DB は変更されない（旧タイトルのまま）。
    @Test func patchWithReadTokenForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "Patch2", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        // 元のタイトルを取得しておく
        let originalTitle = try fixture.db.fetchBook(id: 1)?.title ?? ""
        try await app.test(.router) { client in
            // R トークンで PATCH → 403
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1",
                method: .patch,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(string: #"{"title":"SHOULD_NOT_CHANGE","clearSeries":false,"clearVolume":false,"clearPageDirection":false}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
            // GET /detail でタイトルが変わっていないことを確認
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/detail",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let detail = try decodeDetail(response.body)
                #expect(detail.title == originalTitle)
            }
        }
    }

    /// editToken が nil（サーバが RW トークンを持たない）→ R トークンで PATCH → 403。
    @Test func patchWithoutEditTokenForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "Patch3", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        // editToken を nil に設定したサーバ
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: nil),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1",
                method: .patch,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(string: #"{"title":"NEW","clearSeries":false,"clearVolume":false,"clearPageDirection":false}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    // MARK: - リグレッション

    /// R トークンで /progress は引き続き書き込み可能（PATCH RW-gate のリグレッションなし）。
    @Test func progressStillWorksWithReadToken() async throws {
        let fixture = try TestLibraryFixture(name: "Patch4", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/progress",
                method: .post,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(string: #"{"page":5}"#)
            ) { response in
                #expect(response.status == .ok)
            }
        }
        // DB でも lastPage が更新されていることを確認
        #expect(try fixture.db.loadViewerState(bookID: 1).lastPage == 5)
    }
}
