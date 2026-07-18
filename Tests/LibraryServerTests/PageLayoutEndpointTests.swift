// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer

/// G17 T6b: 特定ページ単頁/見開き override（book_page_layout）の GET(manifest 同梱)/POST エンドポイント。
@Suite("page-layout endpoint")
struct PageLayoutEndpointTests {
    /// manifest の pageOverrides だけを読む最小 Decodable。
    private struct ManifestOverrides: Decodable { let pageOverrides: [String: Int]? }

    private func makeApp(_ lib: ServedLibrary, editToken: String? = "W") -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: editToken),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
    }

    /// override 無しの本は manifest.pageOverrides が nil。
    @Test func manifestHasNoOverridesByDefault() async throws {
        let fixture = try TestLibraryFixture(name: "PL1", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/manifest", method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let m = try JSONDecoder().decode(ManifestOverrides.self, from: Data(buffer: response.body))
                #expect(m.pageOverrides == nil)
            }
        }
    }

    /// POST page-layout（mode=1=forceSolo）→ 200、DB へ永続化され manifest に反映される。
    @Test func postPageLayoutForceSoloPersistsAndReadsBack() async throws {
        let fixture = try TestLibraryFixture(name: "PL2", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/page-layout", method: .post,
                headers: [.authorization: "Bearer W"],
                body: .init(string: #"{"page":2,"mode":1}"#)
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/manifest", method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let m = try JSONDecoder().decode(ManifestOverrides.self, from: Data(buffer: response.body))
                #expect(m.pageOverrides == ["2": 1])
            }
        }
        // DB 直接確認（setPageOverride が book_page_layout に反映されている）。
        let state = try fixture.db.loadViewerState(bookID: bookID)
        #expect(state.overrides == [2: 1])
    }

    /// POST page-layout（mode=0=forcePair）も同様に永続化される。
    @Test func postPageLayoutForcePairPersists() async throws {
        let fixture = try TestLibraryFixture(name: "PL3", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/page-layout", method: .post,
                headers: [.authorization: "Bearer W"],
                body: .init(string: #"{"page":0,"mode":0}"#)
            ) { response in
                #expect(response.status == .ok)
            }
        }
        let state = try fixture.db.loadViewerState(bookID: bookID)
        #expect(state.overrides == [0: 0])
    }

    /// mode 省略（null）→ クリア。既存 override を消して manifest から消える。
    @Test func postPageLayoutNullClearsOverride() async throws {
        let fixture = try TestLibraryFixture(name: "PL4", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        try fixture.db.setPageOverride(bookID: bookID, page: 3, mode: 1)
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/page-layout", method: .post,
                headers: [.authorization: "Bearer W"],
                body: .init(string: #"{"page":3,"mode":null}"#)
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/manifest", method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let m = try JSONDecoder().decode(ManifestOverrides.self, from: Data(buffer: response.body))
                #expect(m.pageOverrides == nil)
            }
        }
        let state = try fixture.db.loadViewerState(bookID: bookID)
        #expect(state.overrides.isEmpty)
    }

    /// R トークン（read-only）は POST page-layout できない → 403。DB も変化しない。
    @Test func postPageLayoutRequiresWrite() async throws {
        let fixture = try TestLibraryFixture(name: "PL5", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/page-layout", method: .post,
                headers: [.authorization: "Bearer R"],
                body: .init(string: #"{"page":1,"mode":1}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        let state = try fixture.db.loadViewerState(bookID: bookID)
        #expect(state.overrides.isEmpty)
    }

    /// 不正な mode 値（0/1 以外）→ 400。
    @Test func postPageLayoutInvalidModeIs400() async throws {
        let fixture = try TestLibraryFixture(name: "PL6", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/page-layout", method: .post,
                headers: [.authorization: "Bearer W"],
                body: .init(string: #"{"page":1,"mode":7}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    /// 負の page → 400。
    @Test func postPageLayoutNegativePageIs400() async throws {
        let fixture = try TestLibraryFixture(name: "PL7", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/page-layout", method: .post,
                headers: [.authorization: "Bearer W"],
                body: .init(string: #"{"page":-1,"mode":1}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func postPageLayoutOutOfRangePageIs400() async throws {
        let fixture = try TestLibraryFixture(name: "PL8", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            // page >= pageCount は 400。上限未チェックだと edit 権限で範囲外 override 行が
            // 無制限に溜まり manifest も肥大化する（G17 Codex Medium）。
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/page-layout", method: .post,
                headers: [.authorization: "Bearer W"],
                body: .init(string: #"{"page":999999,"mode":1}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    /// 認証なし → 401。
    @Test func postPageLayoutNoAuthIs401() async throws {
        let fixture = try TestLibraryFixture(name: "PL8", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/page-layout", method: .post,
                body: .init(string: #"{"page":1,"mode":1}"#)
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    /// 存在しない book id → 404。
    @Test func postPageLayoutUnknownBookIs404() async throws {
        let fixture = try TestLibraryFixture(name: "PL9", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/999/page-layout", method: .post,
                headers: [.authorization: "Bearer W"],
                body: .init(string: #"{"page":1,"mode":1}"#)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    /// 複数ページの override を積んだ状態で manifest がまとめて返す。
    @Test func manifestReturnsMultipleOverrides() async throws {
        let fixture = try TestLibraryFixture(name: "PL10", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        try fixture.db.setPageOverride(bookID: bookID, page: 0, mode: 1)
        try fixture.db.setPageOverride(bookID: bookID, page: 4, mode: 0)
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/manifest", method: .get,
                headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let m = try JSONDecoder().decode(ManifestOverrides.self, from: Data(buffer: response.body))
                #expect(m.pageOverrides == ["0": 1, "4": 0])
            }
        }
    }
}
