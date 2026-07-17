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

    /// G16 A2: PATCH 応答の previous に、変更フィールドの更新前の値が入る（undo 用 pre-image）。
    /// Book 1 は fixture 生成時 rating = 1 % 6 = 1, title = "Book 1"。rating→5, title→"NEW" に変更。
    @Test func patchResponseIncludesPreviousValuesForChangedFields() async throws {
        let fixture = try TestLibraryFixture(name: "Patch5", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1",
                method: .patch,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(string: #"{"title":"NEW","rating":5,"clearSeries":false,"clearVolume":false,"clearPageDirection":false}"#)
            ) { response in
                #expect(response.status == .ok)
                let detail = try decodeDetail(response.body)
                #expect(detail.title == "NEW")
                #expect(detail.rating == 5)
                let previous = try #require(detail.previous)
                #expect(previous.title == "Book 1")
                #expect(previous.rating == 1)
                // 変更していないフィールドは previous でも nil のまま。
                #expect(previous.author == nil)
                #expect(previous.memo == nil)
            }
        }
    }

    /// G16 A2 fix: clear* フラグでの CLEAR も previous に旧値を残す（undo で復元可能にする）。
    /// Book 1 は fixture 生成時 series = "S"。clearSeries=true で series を nil 化 → previous.series は
    /// クリア前の "S" のままであることを確認する（dto.series 自体は nil のまま=SET ではなく CLEAR 経由）。
    @Test func patchResponseIncludesPreviousValueForClearedField() async throws {
        let fixture = try TestLibraryFixture(name: "Patch6", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1",
                method: .patch,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(string: #"{"clearSeries":true,"clearVolume":false,"clearPageDirection":false}"#)
            ) { response in
                #expect(response.status == .ok)
                let detail = try decodeDetail(response.body)
                // series は CLEAR 経由で nil 化されている。
                #expect(detail.series == nil)
                let previous = try #require(detail.previous)
                // previous.series にクリア前の値が残っていること（undo の逆パッチが復元できる）。
                #expect(previous.series == "S")
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

    // MARK: - G16 Codex Medium: 同時 PATCH の pre-image 直列化

    /// 同じ本への 2 件の PATCH がほぼ同時に届いても、両方の応答が「更新前オリジナル値」を
    /// pre-image（previous）として二重に握ってしまわない（lost update 防止）。
    /// どちらが先に着くかは非決定だが、正しく直列化されていれば「両方とも previous がオリジナルの
    /// まま」にはならない（先着した方だけがオリジナルを見て、後着した方は先着の更新結果を見る）。
    /// 直列化が無いと、両方が resolveBook で同じ更新前 row を読んで previous に握ってしまい得る。
    @Test func concurrentPatchesToSameBookSerializePreImage() async throws {
        let fixture = try TestLibraryFixture(name: "PatchConcurrent", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let originalTitle = try #require(try fixture.db.fetchBook(id: 1)?.title)
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()

        nonisolated(unsafe) var previous1: BookPatchDTO?
        nonisolated(unsafe) var previous2: BookPatchDTO?
        try await app.test(.router) { client in
            async let t1: Void = {
                try await client.execute(
                    uri: "/api/v1/libraries/\(lib.uuid)/books/1", method: .patch,
                    headers: [.authorization: "Bearer W", .contentType: "application/json"],
                    body: .init(string: #"{"title":"A","clearSeries":false,"clearVolume":false,"clearPageDirection":false}"#)
                ) { response in
                    #expect(response.status == .ok)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    previous1 = try decoder.decode(BookDetailDTO.self, from: Data(buffer: response.body)).previous
                }
            }()
            async let t2: Void = {
                try await client.execute(
                    uri: "/api/v1/libraries/\(lib.uuid)/books/1", method: .patch,
                    headers: [.authorization: "Bearer W", .contentType: "application/json"],
                    body: .init(string: #"{"title":"B","clearSeries":false,"clearVolume":false,"clearPageDirection":false}"#)
                ) { response in
                    #expect(response.status == .ok)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    previous2 = try decoder.decode(BookDetailDTO.self, from: Data(buffer: response.body)).previous
                }
            }()
            _ = try await (t1, t2)
        }
        let p1 = try #require(previous1)
        let p2 = try #require(previous2)
        // lost update の兆候: 両方が「オリジナルのまま」を pre-image に握っている。
        #expect(!(p1.title == originalTitle && p2.title == originalTitle))
        // どちらか一方は必ずオリジナルを見ている（先着した方）。
        #expect(p1.title == originalTitle || p2.title == originalTitle)
        // 最終値は両方の更新のうちどちらか（両方の PATCH が実際に適用されている）。
        let finalTitle = try fixture.db.fetchBook(id: 1)?.title
        #expect(finalTitle == "A" || finalTitle == "B")
    }
}
