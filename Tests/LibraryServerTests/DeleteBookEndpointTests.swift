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

    private func makeApp(fixture: TestLibraryFixture, trashFile: (@Sendable (URL) throws -> URL?)? = nil, adminTier: Bool = false) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", trashFile: trashFile, adminTier: adminTier),
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

    /// RW トークンで seed 本を DELETE → 200＋BookRestoreDTO ＋ DB から消える（G12b-3c S5）。
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
                #expect(response.status == .ok)
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

    // MARK: - trash 安全不変条件

    /// trashFile が nil のとき ?trash=true → 501 かつ DB 不変。
    @Test func trashWithoutTrashFileReturns501AndDBUnchanged() async throws {
        let fixture = try TestLibraryFixture(name: "TrashNo501", bookCount: 0)
        defer { fixture.cleanup() }

        // path 付きの本を挿入
        let pngPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-nil-\(UUID().uuidString).png").path
        FileManager.default.createFile(atPath: pngPath, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: pngPath) }

        let bookID = try fixture.db.insertBookReturningID(BookRecord(
            id: 0, title: "TrashNil", path: pngPath, dateAdded: Date()
        ))

        let lib = fixture.servedLibrary()
        // trashFile を注入しない（nil のまま）
        let app = makeApp(fixture: fixture, adminTier: true)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)?trash=true",
                method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .notImplemented)
            }
        }
        // DB は変わっていないこと
        let after = try fixture.db.fetchAllBooks()
        #expect(after.count == 1)
    }

    /// trashFile が throw するとき ?trash=true → 500 かつ DB 不変。
    @Test func trashWithThrowingTrashFileReturns500AndDBUnchanged() async throws {
        let fixture = try TestLibraryFixture(name: "Trash500", bookCount: 0)
        defer { fixture.cleanup() }

        // path 付きの本を挿入
        let pngPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-throw-\(UUID().uuidString).png").path
        FileManager.default.createFile(atPath: pngPath, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: pngPath) }

        let bookID = try fixture.db.insertBookReturningID(BookRecord(
            id: 0, title: "TrashThrow", path: pngPath, dateAdded: Date()
        ))

        let lib = fixture.servedLibrary()
        struct TrashError: Error {}
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W",
                          trashFile: { _ in throw TrashError() }, adminTier: true),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)?trash=true",
                method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .internalServerError)
            }
        }
        // DB は変わっていないこと
        let after = try fixture.db.fetchAllBooks()
        #expect(after.count == 1)
    }

    // MARK: - trash 経路（任意）

    /// trashFile が注入されているとき ?trash=true → closure が呼ばれ 200（G12b-3c S5）。
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
                          trashFile: { url in trashedPaths.append(url.path); return nil }, adminTier: true),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)?trash=true",
                method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(trashedPaths == [pngPath])
        // DB からも消えている
        #expect(try fixture.db.fetchAllBooks().isEmpty)
    }
}
