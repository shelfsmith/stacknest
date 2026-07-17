// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import StackroomFormat
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
            let coverVersion: String?
            let dateAdded: Date
            // 動的フィールド（&fields= 検証用・既定 nil）
            let genre: String?; let neta: String?
            let keywordA: String?; let keywordB: String?; let memo: String?
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

    /// order=asc と order=desc で並びが反転する（明示 order がソート既定方向より優先）。
    @Test func orderAscAndDescReverseEachOther() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 5)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            var ascIDs: [Int] = []
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?sort=series&order=asc&per=100", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let page = try Self.makeDecoder().decode(Page.self, from: Data(buffer: response.body))
                ascIDs = page.items.map { $0.id }
            }
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?sort=series&order=desc&per=100", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let page = try Self.makeDecoder().decode(Page.self, from: Data(buffer: response.body))
                #expect(page.items.map { $0.id } == ascIDs.reversed())
            }
        }
    }

    /// 不正な order 値は 400。
    @Test func invalidOrderIs400() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 1)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?order=sideways", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .badRequest)
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

    /// hasCover は Thumbnails/<id>/thumbnail.jpg の存在を反映する（実規約）。
    /// 自動表紙の本は coverImageName == nil のまま thumbnail.jpg を持つため、
    /// coverImageName での判定は不正（手動表紙のみ true になってしまう）。
    @Test func hasCoverReflectsThumbnailFileExistence() async throws {
        let fixture = try TestLibraryFixture(name: "HC", bookCount: 2)   // 両方 coverImageName nil
        defer { fixture.cleanup() }
        try fixture.addCover(bookID: 1)   // 自動表紙相当: ファイルのみ配置・DB は触らない
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
                #expect(book1.hasCover == true)
                #expect(book2.hasCover == false)
            }
        }
    }

    /// per は 500 までクランプ（4.2b-1b-1: 200→500 緩和）。
    @Test func perClampsAt500() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 3)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?per=501", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let page = try Self.makeDecoder().decode(BookPageDTO.self, from: Data(buffer: response.body))
                #expect(page.perPage == 500)
            }
        }
    }

    /// q 検索はキーワード列にもヒットする（FTS=searchBooks 経由・旧 contains は title/series/author のみ）。
    @Test func searchMatchesKeywordViaFTS() async throws {
        let fixture = try TestLibraryFixture(name: "FTS", bookCount: 2)
        defer { fixture.cleanup() }
        try fixture.db.insertBook(BookRecord(
            id: 0, title: "Plain", dateAdded: Date(), keywordA: "Zephyrkw"))
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books?q=Zephyrkw&per=100", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let page = try Self.makeDecoder().decode(BookPageDTO.self, from: Data(buffer: response.body))
                #expect(page.items.contains { $0.title == "Plain" })
            }
        }
    }

    /// 表紙ありの本は coverVersion 非 nil・表紙なしは nil（Web の ?v= 用）。
    @Test func coverVersionExposedForBooksWithCover() async throws {
        let fixture = try TestLibraryFixture(name: "CV", bookCount: 2)   // 両方 coverImageName nil
        defer { fixture.cleanup() }
        try fixture.addCover(bookID: 1)   // 自動表紙相当: ファイルのみ配置・DB は触らない
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
                #expect(book1.coverVersion != nil)
                #expect(book2.coverVersion == nil)
            }
        }
    }

    /// 全列ソート: rating で昇順整列される（fixture の値に依存しない頑健な検査）。
    @Test func sortByRatingAscending() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 5)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?sort=rating&order=asc&per=100", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let page = try Self.makeDecoder().decode(Page.self, from: Data(buffer: response.body))
                let ratings = page.items.map { $0.rating }
                #expect(ratings == ratings.sorted())
            }
        }
    }

    /// &fields=genre のみ要求 → genre 以外の追加フィールドは nil のまま。
    @Test func fieldsParamFillsOnlyRequestedExtras() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 3)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?fields=genre&per=100", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let page = try Self.makeDecoder().decode(Page.self, from: Data(buffer: response.body))
                #expect(page.items.allSatisfy { $0.neta == nil && $0.memo == nil && $0.keywordA == nil })
            }
        }
    }

    /// 4.2c-6c: keywordC が field/sort として HTTP で受理される（allowedFields＋BookSortKey の回帰ガード）。
    @Test func keywordCFieldAndSortAccepted() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 3)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?fields=keywordC&sort=keywordC&order=asc&per=100", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)   // keywordC が未対応なら sort=keywordC で 400 になる
                let page = try Self.makeDecoder().decode(Page.self, from: Data(buffer: response.body))
                #expect(page.items.count <= 3)
            }
        }
    }

    /// fields 指定なし → 追加フィールドは全て nil。
    @Test func noFieldsParamLeavesAllExtrasNil() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 3)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?per=100", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let page = try Self.makeDecoder().decode(Page.self, from: Data(buffer: response.body))
                #expect(page.items.allSatisfy { $0.genre == nil && $0.neta == nil && $0.memo == nil })
            }
        }
    }

    /// genre で並べても、fields=genre を要求していなければ応答の genre は nil（fill→sort→slice→mask）。
    @Test func sortByGenreWorksEvenWhenFieldNotRequested() async throws {
        let (fixture, app, uuid) = try makeApp(bookCount: 5)
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books?sort=genre&order=asc&per=100", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let page = try Self.makeDecoder().decode(Page.self, from: Data(buffer: response.body))
                #expect(page.items.count <= 5)
                #expect(page.items.allSatisfy { $0.genre == nil })
            }
        }
    }

    /// G15 V3: filename にはフルパスではなく basename が入る（内蔵ビューア対応判定用）。
    @Test func listIncludesFilenameBasename() async throws {
        let fx = try TestLibraryFixture(name: "Filename", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let id = try fx.addRealBook(zipFixtureNamed: "three_pages")   // path=<bundle>/three_pages.zip
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: true),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books?per=50", method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let page = try Self.makeDecoder().decode(BookPageDTO.self, from: Data(buffer: response.body))
                let item = try #require(page.items.first { $0.id == id })
                #expect(item.filename == "three_pages.zip")   // basename が入る
            }
        }
    }
}
