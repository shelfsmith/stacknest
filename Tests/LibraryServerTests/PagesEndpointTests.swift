// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("Pages endpoint")
struct PagesEndpointTests {
    @Test func pageReturnsImageBytesWithCacheHeaders() async throws {
        let fixture = try TestLibraryFixture(name: "P", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/pages/2", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                #expect(Data(buffer: response.body).prefix(2) == Data([0xFF, 0xD8]))
                #expect(response.headers[.eTag] != nil)
                #expect(response.headers[.cacheControl]?.contains("immutable") == true)
            }
            // 範囲外 → 404
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/pages/99", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    /// 同じ本へ連続リクエストしたときに BookContent ハンドルが再利用される（キャッシュ実証）。
    @Test func handleCacheReusesContent() async throws {
        let cache = BookContentCache(ttlSeconds: 60)
        let fixture = try TestLibraryFixture(name: "H", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let row = try #require(try fixture.db.fetchBook(id: bookID))
        let c1 = try await cache.content(for: row, libraryUUID: "u")
        let c2 = try await cache.content(for: row, libraryUUID: "u")
        // 同一インスタンス再利用の検証。BookContent 実装は全て actor（参照型）のため
        // AnyObject へキャストして同一性比較する（existential 同士の === は不可）。
        // 注意: `#expect((c1 as AnyObject) === (c2 as AnyObject))` とマクロ内に書くと
        // swift-frontend 6.2.4 が existential 消去サンクの SILGen でクラッシュするため外出しする。
        let isSameInstance = (c1 as AnyObject) === (c2 as AnyObject)
        #expect(isSameInstance)
    }
}
