// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("Cover & manifest endpoints")
struct ContentEndpointTests {
    /// fixture: 実在 zip（PDF 5 ページ入り）を path に持つ本 1 冊 + 表紙 JPEG を Thumbnails に配置。
    private func makeContentApp() throws -> (TestLibraryFixture, some ApplicationProtocol, String, Int) {
        let fixture = try TestLibraryFixture(name: "C", bookCount: 0)
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        try fixture.addCover(bookID: bookID)   // 実規約: Thumbnails/<id>/thumbnail.jpg
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        return (fixture, app, lib.uuid, bookID)
    }

    @Test func coverReturnsJPEGWithETagAndImmutable() async throws {
        let (fixture, app, uuid, bookID) = try makeContentApp()
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            var etag = ""
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books/\(bookID)/cover", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                #expect(Data(buffer: response.body).prefix(2) == Data([0xFF, 0xD8]))
                etag = response.headers[.eTag] ?? ""
                #expect(!etag.isEmpty)
                #expect(response.headers[.cacheControl]?.contains("immutable") == true)
            }
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books/\(bookID)/cover", method: .get,
                headers: [.authorization: "Bearer tk", .ifNoneMatch: etag]
            ) { response in
                #expect(response.status == .notModified)
            }
        }
    }

    @Test func coverMissingIs404() async throws {
        let fixture = try TestLibraryFixture(name: "NC", bookCount: 1)   // Thumbnails 未配置の本
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/cover", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test func manifestReportsPageCountDirectionFormat() async throws {
        let (fixture, app, uuid, bookID) = try makeContentApp()
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books/\(bookID)/manifest", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                struct M: Decodable { let pageCount: Int; let format: String; let etag: String }
                let m = try JSONDecoder().decode(M.self, from: Data(buffer: response.body))
                #expect(m.pageCount == 5)
                #expect(m.format == "archive")
                #expect(!m.etag.isEmpty)
            }
        }
    }

    /// 存在しない book id は 404（resolveBook の写像確認）。
    @Test func manifestUnknownBookIs404() async throws {
        let (fixture, app, uuid, _) = try makeContentApp()
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books/9999/manifest", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    /// cover の ETag は thumbnail.jpg 自身の mtime+size 由来（原本ではなく表紙の変化を追跡）。
    /// 単一 app.test ブロック内で 2 リクエストを実行する（既存 coverReturnsJPEG... と同様 —
    /// 別ブロックに分けると #expect が var をキャプチャして SendableClosureCaptures エラーになる）。
    @Test func coverETagTracksThumbnailFile() async throws {
        let (fixture, app, uuid, bookID) = try makeContentApp()
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            var etag1 = ""
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books/\(bookID)/cover", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in etag1 = response.headers[.eTag] ?? "" }
            // 表紙を書き換え（サイズ変更で mtime+size が変わる）
            try fixture.rewriteCover(bookID: bookID)
            let previousETag = etag1
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books/\(bookID)/cover", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.headers[.eTag] != nil)
                #expect(response.headers[.eTag] != previousETag)
            }
        }
    }

    /// ロック庫は X-Library-Token なしでは cover も 403（LibraryResolver ゲート共用の確認）。
    @Test func lockedLibraryCoverRequiresLibraryToken() async throws {
        let fixture = try TestLibraryFixture(name: "LK", bookCount: 0, locked: true, password: "pw")
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        try fixture.addCover(bookID: bookID)
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }
}
