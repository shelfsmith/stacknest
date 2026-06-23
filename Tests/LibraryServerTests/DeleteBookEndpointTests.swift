// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import StackroomFormat
@testable import LibraryServer

@Suite("DELETE /books endpoint")
struct DeleteBookEndpointTests {
    // MARK: - helpers

    private func makeApp(fixture: TestLibraryFixture, trashFile: (@Sendable (URL) throws -> Void)? = nil) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", trashFile: trashFile),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    // MARK: - 権限制限

    /// R トークンで DELETE → 403。
    @Test func deleteWithReadTokenForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "DelForbidden", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1",
                method: .delete,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    // MARK: - 正常系

    /// RW トークンで seed 本を DELETE → 204 ＋ DB から消える。
    @Test func deleteWithWriteTokenRemovesBook() async throws {
        let fixture = try TestLibraryFixture(name: "DelOK", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        // 削除前に存在確認
        let before = try fixture.db.fetchAllBooks()
        #expect(before.count == 1)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1",
                method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .noContent)
            }
        }

        // 削除後に DB から消えていることを確認
        let after = try fixture.db.fetchAllBooks()
        #expect(after.isEmpty)
    }

    // MARK: - 不在 ID

    /// 存在しない ID への DELETE → 404。
    @Test func deleteNonExistentBookReturns404() async throws {
        let fixture = try TestLibraryFixture(name: "DelNotFound", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/9999",
                method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    // MARK: - trash 経路（任意）

    /// trashFile が注入されているとき ?trash=true → closure が呼ばれ 204。
    @Test func deleteWithTrashCallsTrashFile() async throws {
        let fixture = try TestLibraryFixture(name: "DelTrash", bookCount: 0)
        defer { fixture.cleanup() }

        // path 付きの本を挿入
        let pngPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-test-\(UUID().uuidString).png").path
        FileManager.default.createFile(atPath: pngPath, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: pngPath) }

        let bookID = try fixture.db.insertBookReturningID(BookRecord(
            id: 0, title: "TrashMe", path: pngPath, dateAdded: Date()
        ))

        let lib = fixture.servedLibrary()
        nonisolated(unsafe) var trashedPaths: [String] = []
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W",
                          trashFile: { url in trashedPaths.append(url.path) }),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)?trash=true",
                method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .noContent)
            }
        }
        #expect(trashedPaths == [pngPath])
        // DB からも消えている
        #expect(try fixture.db.fetchAllBooks().isEmpty)
    }
}
