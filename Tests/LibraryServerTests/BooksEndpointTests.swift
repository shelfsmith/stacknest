// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("Books endpoint")
struct BooksEndpointTests {
    private func makeApp(bookCount: Int) throws -> (TestLibraryFixture, some ApplicationProtocol, String) {
        let fixture = try TestLibraryFixture(name: "L", bookCount: bookCount)
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        return (fixture, app, lib.uuid)
    }

    /// JSON の Date はサーバ共通エンコーダと同じ ISO8601 でデコードする（plan 設計ノート）。
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct Page: Decodable {
        struct Item: Decodable {
            let id: Int; let title: String; let series: String?
            let volume: Double?; let rating: Int; let unseen: Bool
            let pages: Int?; let lastPage: Int?; let hasCover: Bool
            let dateAdded: Date
        }
        let items: [Item]; let total: Int; let page: Int; let perPage: Int
    }

    @Test func paginationSlicesAndReportsTotal() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 25)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?page=2&per=10", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let page = try Self.makeDecoder().decode(Page.self, from: Data(buffer: response.body))
                #expect(page.total == 25)
                #expect(page.items.count == 10)
                #expect(page.page == 2)
            }
        }
    }

    @Test func searchFiltersByTitleContains() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 12)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?q=Book%201&per=100", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                let page = try Self.makeDecoder().decode(Page.self, from: Data(buffer: response.body))
                // "Book 1", "Book 10", "Book 11", "Book 12"
                #expect(page.total == 4)
            }
        }
    }

    @Test func sortBySeriesOrdersByVolume() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 5)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?sort=series&per=100", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                let page = try Self.makeDecoder().decode(Page.self, from: Data(buffer: response.body))
                let volumes = page.items.map { $0.volume ?? 0 }
                #expect(volumes == volumes.sorted())
            }
        }
    }

    @Test func invalidSortKeyIs400() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 1)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?sort=bogus", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    /// last_page を保存した本だけ lastPage が載る（fetchAllViewerStates 経由の進行状況）。
    @Test func progressIsExposedOnlyForPersistedBooks() async throws {
        let fixture = try TestLibraryFixture(name: "L", bookCount: 2)
        defer { fixture.cleanup() }
        try fixture.db.saveViewerState(bookID: 1, spreadEnabled: false, coverOffset: true, lastPage: 7)
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books?per=100", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                let page = try Self.makeDecoder().decode(Page.self, from: Data(buffer: response.body))
                let book1 = try #require(page.items.first { $0.id == 1 })
                let book2 = try #require(page.items.first { $0.id == 2 })
                #expect(book1.lastPage == 7)
                #expect(book2.lastPage == nil)
            }
        }
    }
}
