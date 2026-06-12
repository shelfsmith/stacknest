// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("Direction endpoint")
struct DirectionTests {
    // MARK: - helpers

    /// manifest の direction フィールドだけを読む最小 Decodable。
    private struct ManifestDirection: Decodable { let direction: String }

    // MARK: - 正常系

    /// ltr を POST → 200、manifest が "ltr" を返す。
    @Test func postDirectionLtrUpdatesManifest() async throws {
        let fixture = try TestLibraryFixture(name: "DirW1", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk", defaultPageDirection: .rightToLeft),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            // 書き込み
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/direction", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"direction":"ltr"}"#)
            ) { response in
                #expect(response.status == .ok)
            }
            // manifest で確認
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/manifest", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let m = try JSONDecoder().decode(
                    ManifestDirection.self, from: Data(buffer: response.body))
                #expect(m.direction == "ltr")
            }
        }
    }

    /// rtl を POST → 200、manifest が "rtl" を返す。
    @Test func postDirectionRtlUpdatesManifest() async throws {
        let fixture = try TestLibraryFixture(name: "DirW2", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk", defaultPageDirection: .leftToRight),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            // 書き込み
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/direction", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"direction":"rtl"}"#)
            ) { response in
                #expect(response.status == .ok)
            }
            // manifest で確認（defaultPageDirection: .leftToRight を上書きしている）
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/manifest", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let m = try JSONDecoder().decode(
                    ManifestDirection.self, from: Data(buffer: response.body))
                #expect(m.direction == "rtl")
            }
        }
    }

    /// null を POST → 200、DB の page_direction が nil に戻り manifest は既定方向を返す。
    @Test func postDirectionNullClearsOverride() async throws {
        let fixture = try TestLibraryFixture(name: "DirW3", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        // まず ltr を書き込んでから null でリセット
        try fixture.db.updatePageDirection(bookID: bookID, direction: .leftToRight)
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk", defaultPageDirection: .rightToLeft),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/direction", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"direction":null}"#)
            ) { response in
                #expect(response.status == .ok)
            }
            // override が消えたので defaultPageDirection "rtl" が返る
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/manifest", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let m = try JSONDecoder().decode(
                    ManifestDirection.self, from: Data(buffer: response.body))
                #expect(m.direction == "rtl")
            }
        }
        // DB 直接確認
        let row = try fixture.db.fetchBook(id: bookID)
        #expect(row?.pageDirection == nil)
    }

    // MARK: - 異常系

    /// 不正な direction 文字列 → 400。
    @Test func invalidDirectionIs400() async throws {
        let fixture = try TestLibraryFixture(name: "DirW4", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/direction", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"direction":"xxx"}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    /// 認証なし → 401。
    @Test func noAuthIs401() async throws {
        let fixture = try TestLibraryFixture(name: "DirW5", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/direction", method: .post,
                body: .init(string: #"{"direction":"ltr"}"#)
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    /// 存在しない book id → 404。
    @Test func unknownBookIs404() async throws {
        let fixture = try TestLibraryFixture(name: "DirW6", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/999/direction", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"direction":"ltr"}"#)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
