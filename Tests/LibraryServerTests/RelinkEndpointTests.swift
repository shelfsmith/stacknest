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
    @Test func relinkUpdatesPathAndClearsHash() async throws {
        let fixture = try TestLibraryFixture(name: "RelinkOK", bookCount: 0)
        defer { fixture.cleanup() }
        // path 付きの本を挿入し、content_hash を別途セットする（BookRecord に hash フィールドはない）。
        let bookID = try fixture.db.insertBookReturningID(BookRecord(
            id: 0, title: "Relinkable", path: "/old/path.zip", dateAdded: Date()
        ))
        try fixture.db.updateBookContentHash(id: bookID, hash: "deadbeef", size: 123, mtime: 456)
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        let body = try JSONEncoder().encode(RelinkRequest(newPath: "/new/path.zip"))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/relink",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { resp in #expect(resp.status == .noContent) }
        }
        let updated = try fixture.db.fetchBook(id: bookID)
        #expect(updated?.path == "/new/path.zip")
        #expect(updated?.contentHash == nil)
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
