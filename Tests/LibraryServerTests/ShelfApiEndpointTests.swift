// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import StackroomFormat
@testable import LibraryServer

@Suite("Shelf API endpoint tests")
struct ShelfApiEndpointTests {
    // MARK: - helpers

    private func makeApp(fixture: TestLibraryFixture) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    private func decodeShelf(_ buffer: ByteBuffer) throws -> ShelfDTO {
        try JSONDecoder().decode(ShelfDTO.self, from: Data(buffer: buffer))
    }

    private func decodeShelves(_ buffer: ByteBuffer) throws -> [ShelfDTO] {
        try JSONDecoder().decode([ShelfDTO].self, from: Data(buffer: buffer))
    }

    private func decodeConditions(_ buffer: ByteBuffer) throws -> SmartShelfConditions {
        try JSONDecoder().decode(SmartShelfConditions.self, from: Data(buffer: buffer))
    }

    private func decodeBookPage(_ buffer: ByteBuffer) throws -> BookPageDTO {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookPageDTO.self, from: Data(buffer: buffer))
    }

    private func jsonBody<T: Encodable>(_ value: T) throws -> ByteBuffer {
        .init(bytes: Array(try JSONEncoder().encode(value)))
    }

    // MARK: - ① 手動棚の作成

    /// POST /shelves → 200・isSmart=false・DB に反映される。
    @Test func createManualShelf() async throws {
        let fixture = try TestLibraryFixture(name: "ShelfCreate", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: try jsonBody(ShelfCreateRequest(title: "My Shelf", isSmart: false))
            ) { response in
                #expect(response.status == .ok)
                let dto = try decodeShelf(response.body)
                #expect(dto.title == "My Shelf")
                #expect(dto.isSmart == false)
                #expect(dto.id > 0)
            }
        }

        // DB に反映されているか確認
        let shelves = try fixture.db.fetchAllShelves()
        #expect(shelves.contains { $0.title == "My Shelf" && !$0.isSmart })
    }

    // MARK: - ② スマート棚の作成

    /// isSmart=true かつ conditions なし → 400。
    @Test func createSmartShelfWithoutConditionsReturns400() async throws {
        let fixture = try TestLibraryFixture(name: "SmartNoCond", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: try jsonBody(ShelfCreateRequest(title: "SmartX", isSmart: true, conditions: nil))
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    /// isSmart=true かつ conditions あり → 200・isSmart=true。
    @Test func createSmartShelfWithConditions() async throws {
        let fixture = try TestLibraryFixture(name: "SmartWithCond", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        let cond = SmartShelfConditions(version: 1, match: .all, rules: [])
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: try jsonBody(ShelfCreateRequest(title: "Smart", isSmart: true, conditions: cond))
            ) { response in
                #expect(response.status == .ok)
                let dto = try decodeShelf(response.body)
                #expect(dto.title == "Smart")
                #expect(dto.isSmart == true)
            }
        }
    }

    // MARK: - ③ 認可（R トークンで POST → 403）

    /// R トークンで POST /shelves → 403。
    @Test func createShelfWithReadTokenForbidden() async throws {
        let fixture = try TestLibraryFixture(name: "ShelfForbidden", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves",
                method: .post,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: try jsonBody(ShelfCreateRequest(title: "X", isSmart: false))
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    // MARK: - ④ PATCH（更新）

    /// PATCH スマート棚の改名＋条件 any に変更 → 200。
    @Test func patchSmartShelfRenameAndUpdateConditions() async throws {
        let fixture = try TestLibraryFixture(name: "PatchSmart", bookCount: 0)
        defer { fixture.cleanup() }

        // スマート棚を事前作成
        let cond = SmartShelfConditions(version: 1, match: .all, rules: [])
        let shelfID = try fixture.db.createSmartShelf(title: "OldName", conditions: cond)

        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        let newCond = SmartShelfConditions(version: 1, match: .any, rules: [])
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(shelfID)",
                method: .patch,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: try jsonBody(ShelfUpdateRequest(title: "NewName", conditions: newCond))
            ) { response in
                #expect(response.status == .ok)
                let dto = try decodeShelf(response.body)
                #expect(dto.title == "NewName")
                #expect(dto.isSmart == true)
            }
        }

        // DB で conditions が any に変わっていることを確認
        let updated = try fixture.db.fetchSmartShelfConditions(id: shelfID)
        #expect(updated?.match == .any)
    }

    /// PATCH 手動棚に conditions を送る → 409。
    @Test func patchManualShelfWithConditionsReturns409() async throws {
        let fixture = try TestLibraryFixture(name: "PatchManualCond", bookCount: 0)
        defer { fixture.cleanup() }

        let shelfID = try fixture.db.createUserShelf(title: "Manual")
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        let cond = SmartShelfConditions(version: 1, match: .all, rules: [])
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(shelfID)",
                method: .patch,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: try jsonBody(ShelfUpdateRequest(title: nil, conditions: cond))
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    /// PATCH 不在 ID → 404。
    @Test func patchNonExistentShelfReturns404() async throws {
        let fixture = try TestLibraryFixture(name: "PatchNotFound", bookCount: 0)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/9999",
                method: .patch,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: try jsonBody(ShelfUpdateRequest(title: "X"))
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    // MARK: - ⑤ DELETE

    /// DELETE 手動棚 → 204・DB から消える。
    @Test func deleteManualShelf() async throws {
        let fixture = try TestLibraryFixture(name: "DeleteShelf", bookCount: 0)
        defer { fixture.cleanup() }

        let shelfID = try fixture.db.createUserShelf(title: "ToDelete")
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(shelfID)",
                method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .noContent)
            }
        }

        // DB から消えていることを確認
        let shelves = try fixture.db.fetchAllShelves()
        #expect(!shelves.contains { $0.id == shelfID })
    }

    /// DELETE お気に入り棚 → 409（削除保護）。
    @Test func deleteFavoritesShelfReturns409() async throws {
        let fixture = try TestLibraryFixture(name: "DeleteFav", bookCount: 0)
        defer { fixture.cleanup() }

        let favID = try fixture.db.ensureFavoritesShelf()
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(favID)",
                method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .conflict)
            }
        }

        // お気に入り棚は DB に残っていること
        let shelves = try fixture.db.fetchAllShelves()
        #expect(shelves.contains { $0.id == favID })
    }

    // MARK: - ⑥ conditions GET / PUT

    /// GET conditions → 200・match=all。PUT で any に変更 → 200。手動棚への GET conditions → 409。
    @Test func conditionsGetAndPut() async throws {
        let fixture = try TestLibraryFixture(name: "Conditions", bookCount: 0)
        defer { fixture.cleanup() }

        let initCond = SmartShelfConditions(version: 1, match: .all, rules: [])
        let shelfID = try fixture.db.createSmartShelf(title: "Smart", conditions: initCond)
        let manualID = try fixture.db.createUserShelf(title: "Manual")

        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            // GET conditions → 200・match=all
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(shelfID)/conditions",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let cond = try decodeConditions(response.body)
                #expect(cond.match == .all)
            }

            // PUT conditions に any を送信 → 200
            let newCond = SmartShelfConditions(version: 1, match: .any, rules: [])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(shelfID)/conditions",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: try jsonBody(newCond)
            ) { response in
                #expect(response.status == .ok)
                let cond = try decodeConditions(response.body)
                #expect(cond.match == .any)
            }

            // 手動棚の GET conditions → 409
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(manualID)/conditions",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    // MARK: - ⑥-b G13/F1: listShelves が bookCount を返す

    /// GET /shelves → 手動棚/お気に入り棚は playlist 所属数、スマート棚は条件評価数が
    /// 各 ShelfDTO.bookCount に一致すること。
    @Test func listShelvesReturnsBookCounts() async throws {
        let fixture = try TestLibraryFixture(name: "ShelfCounts", bookCount: 0)
        defer { fixture.cleanup() }

        // 3冊挿入
        let id1 = try fixture.db.insertBookReturningID(BookRecord(id: 0, title: "Book1", dateAdded: Date()))
        let id2 = try fixture.db.insertBookReturningID(BookRecord(id: 0, title: "Book2", dateAdded: Date()))
        let id3 = try fixture.db.insertBookReturningID(BookRecord(id: 0, title: "Book3", dateAdded: Date()))

        // 手動棚: 2冊所属
        let shelfID = try fixture.db.createUserShelf(title: "Manual")
        try fixture.db.appendBooksToShelf(playlistID: shelfID, bookIDs: [id1, id2])

        // お気に入り棚: 1冊所属
        let favID = try fixture.db.ensureFavoritesShelf()
        try fixture.db.appendBooksToShelf(playlistID: favID, bookIDs: [id3])

        // スマート棚: rating >= 0 で全冊(3冊)にマッチする条件
        let cond = SmartShelfConditions(
            version: 1, match: .all,
            rules: [SmartShelfRule(id: UUID(), field: .rating, op: .gte, value: .int(0))]
        )
        let smartID = try fixture.db.createSmartShelf(title: "Smart", conditions: cond)

        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let shelves = try decodeShelves(response.body)
                let manual = shelves.first { $0.id == shelfID }
                let favorites = shelves.first { $0.id == favID }
                let smart = shelves.first { $0.id == smartID }
                #expect(manual?.bookCount == 2)
                #expect(favorites?.bookCount == 1)
                #expect(smart?.bookCount == 3)
            }
        }
    }

    // MARK: - ⑦-new 追加テスト（Minor-4 / Nit-5 対応）

    /// PATCH お気に入り棚の改名 → 409（favorites は改名禁止）。
    @Test func patchFavoritesRenameReturns409() async throws {
        let fixture = try TestLibraryFixture(name: "ShelfFavPatch", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let favID = try fixture.db.ensureFavoritesShelf()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(favID)", method: .patch,
                                     headers: [.authorization: "Bearer W", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"title":"改名禁止"}"#)) { res in
                #expect(res.status == .conflict)
            }
        }
    }

    /// 無トークンで POST /shelves → 401。
    @Test func noTokenReturns401() async throws {
        let fixture = try TestLibraryFixture(name: "ShelfNoToken", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/shelves", method: .post,
                                     headers: [.contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"title":"X","isSmart":false}"#)) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    /// 手動棚に PUT conditions → 409（手動棚は conditions を持てない）。
    @Test func putConditionsOnManualReturns409() async throws {
        let fixture = try TestLibraryFixture(name: "ShelfManualCond", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let manualID = try fixture.db.createUserShelf(title: "手動")
        let app = makeApp(fixture: fixture)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(manualID)/conditions", method: .put,
                                     headers: [.authorization: "Bearer W", .contentType: "application/json"],
                                     body: ByteBuffer(string: #"{"version":1,"match":"all","rules":[]}"#)) { res in
                #expect(res.status == .conflict)
            }
        }
    }

    // MARK: - ⑦ membership（所属追加/除去）

    /// 追加 204 → GET /books?scope=shelf&scopeId=N で total=2 →
    /// 除去 204 → total=1 → スマート棚への所属操作=409。
    @Test func membershipAddAndRemove() async throws {
        let fixture = try TestLibraryFixture(name: "Membership", bookCount: 0)
        defer { fixture.cleanup() }

        // 2冊挿入
        let id1 = try fixture.db.insertBookReturningID(BookRecord(id: 0, title: "Book1", dateAdded: Date()))
        let id2 = try fixture.db.insertBookReturningID(BookRecord(id: 0, title: "Book2", dateAdded: Date()))

        // 手動棚とスマート棚を作成
        let shelfID = try fixture.db.createUserShelf(title: "Shelf")
        let smartCond = SmartShelfConditions(version: 1, match: .all, rules: [])
        let smartID = try fixture.db.createSmartShelf(title: "Smart", conditions: smartCond)

        let lib = fixture.servedLibrary()
        let app = makeApp(fixture: fixture)

        try await app.test(.router) { client in
            // 2冊を手動棚に追加 → 204
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(shelfID)/books",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: try jsonBody(ShelfBooksRequest(bookIDs: [id1, id2]))
            ) { response in
                #expect(response.status == .noContent)
            }

            // GET /books?scope=shelf&scopeId=shelfID → total=2
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books?scope=shelf&scopeId=\(shelfID)",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let page = try decodeBookPage(response.body)
                #expect(page.total == 2)
            }

            // 1冊を除去 → 204
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(shelfID)/books",
                method: .delete,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: try jsonBody(ShelfBooksRequest(bookIDs: [id1]))
            ) { response in
                #expect(response.status == .noContent)
            }

            // GET /books?scope=shelf&scopeId=shelfID → total=1
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books?scope=shelf&scopeId=\(shelfID)",
                method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let page = try decodeBookPage(response.body)
                #expect(page.total == 1)
            }

            // スマート棚への追加 → 409
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(smartID)/books",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: try jsonBody(ShelfBooksRequest(bookIDs: [id2]))
            ) { response in
                #expect(response.status == .conflict)
            }

            // スマート棚からの除去 → 409
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves/\(smartID)/books",
                method: .delete,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: try jsonBody(ShelfBooksRequest(bookIDs: [id2]))
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }
}
