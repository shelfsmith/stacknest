// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import StackroomFormat
@testable import LibraryServer

@Suite("POST /books/:id/relink endpoint")
struct RelinkEndpointTests {

    private func makeApp(fixture: TestLibraryFixture) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    /// relink → path 更新＋contentHash が NULL 化。
    /// newPath はライブラリバンドル配下（許可ルートの一つ）を使う — セキュリティ修正
    /// （newPath の許可ルート検証）後もこの正当な入力は回帰なく成功する必要がある。
    @Test func relinkUpdatesPathAndClearsHash() async throws {
        let fixture = try TestLibraryFixture(name: "RelinkOK", bookCount: 0)
        defer { fixture.cleanup() }
        let oldPath = fixture.bundleURL.appendingPathComponent("old/path.zip").path
        // path 付きの本を挿入し、content_hash を別途セットする（BookRecord に hash フィールドはない）。
        let bookID = try fixture.db.insertBookReturningID(BookRecord(
            id: 0, title: "Relinkable", path: oldPath, dateAdded: Date()
        ))
        try fixture.db.updateBookContentHash(id: bookID, hash: "deadbeef", size: 123, mtime: 456)
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let newPath = fixture.bundleURL.appendingPathComponent("new/path.zip").path
        let body = try JSONEncoder().encode(RelinkRequest(newPath: newPath))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/relink",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .noContent) }
        }
        let updated = try fixture.db.fetchBook(id: bookID)
        #expect(updated?.path == newPath)
        #expect(updated?.contentHash == nil)
    }

    // MARK: - セキュリティ修正: newPath の許可ルート検証（Arbitrary File Read via relink→file）

    /// relink の newPath が許可ルート（バンドル配下／監視フォルダ／現存する他本のディレクトリ）の
    /// 外にあるとき、403 forbidden で拒否され、DB 上の path は変更されない。
    /// 修正前は client 供給パスを無検証で relinkBook に渡していたため、edit tier のクライアントが
    /// 任意のホストパス（例: `~/.ssh/id_rsa`）へ relink し、続けて GET .../file（read tier）で
    /// 中身を読み出せた（secret disclosure）。
    @Test func relinkToPathOutsideAllowedRootsIsForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "RelinkOutsideRoots", bookCount: 0)
        defer { fixture.cleanup() }
        let oldPath = fixture.bundleURL.appendingPathComponent("old/path.zip").path
        let bookID = try fixture.db.insertBookReturningID(BookRecord(
            id: 0, title: "Relinkable", path: oldPath, dateAdded: Date()
        ))
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        // バンドル外・監視フォルダでもない一時ディレクトリ（許可ルートのどれにも属さない）。
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relink-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outsidePath = outsideDir.appendingPathComponent("victim.zip").path

        let body = try JSONEncoder().encode(RelinkRequest(newPath: outsidePath))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/relink",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .forbidden) }
        }
        let updated = try fixture.db.fetchBook(id: bookID)
        #expect(updated?.path == oldPath)   // 拒否され、path は変更されていない
    }

    /// 許可ルート内（ライブラリバンドル配下）への relink は許可ルート検証を追加した後も
    /// 従来どおり成功する（回帰なし）。
    @Test func relinkToPathWithinBundleRootSucceeds() async throws {
        let fixture = try TestLibraryFixture(name: "RelinkWithinRoot", bookCount: 0)
        defer { fixture.cleanup() }
        let oldPath = fixture.bundleURL.appendingPathComponent("old/path.zip").path
        let bookID = try fixture.db.insertBookReturningID(BookRecord(
            id: 0, title: "Relinkable", path: oldPath, dateAdded: Date()
        ))
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        let newPath = fixture.bundleURL.appendingPathComponent("new/path.zip").path
        let body = try JSONEncoder().encode(RelinkRequest(newPath: newPath))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/relink",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .noContent) }
        }
        let updated = try fixture.db.fetchBook(id: bookID)
        #expect(updated?.path == newPath)
    }

    /// 不在 ID → 404。
    @Test func relinkNonExistentReturns404() async throws {
        let fixture = try TestLibraryFixture(name: "RelinkNotFound", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let body = try JSONEncoder().encode(RelinkRequest(newPath: "/x.zip"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/9999/relink",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .notFound) }
        }
    }

    /// 空パス → 400。
    @Test func relinkEmptyPathReturns400() async throws {
        let fixture = try TestLibraryFixture(name: "RelinkEmpty", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let body = try JSONEncoder().encode(RelinkRequest(newPath: ""))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/relink",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .badRequest) }
        }
    }

    /// R トークン → 403。
    @Test func relinkWithReadTokenForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "RelinkForbidden", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let body = try JSONEncoder().encode(RelinkRequest(newPath: "/x.zip"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/relink",
                method: .post,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .forbidden) }
        }
    }
}
