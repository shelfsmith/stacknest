// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer
import LibraryServerAPI
import StackroomFormat
import LibraryStore

@Suite("Remote browse endpoints (4.2b-1b-2b)")
struct RemoteBrowseEndpointsTests {
    private func dec() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test func shelvesListsUserShelf() async throws {
        let fixture = try TestLibraryFixture(name: "Sh", bookCount: 1)
        defer { fixture.cleanup() }
        _ = try fixture.db.createUserShelf(title: "手動棚")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/shelves", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .ok)
                let shelves = try dec().decode([ShelfDTO].self, from: Data(buffer: resp.body))
                #expect(shelves.contains { $0.title == "手動棚" })
            }
        }
    }

    @Test func bookDetailReturnsFullFields() async throws {
        let fixture = try TestLibraryFixture(name: "Dt", bookCount: 0)
        defer { fixture.cleanup() }
        let id = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "Full", dateAdded: Date(),
                       keywordA: "kw", neta: nil, series: nil)
        )
        // Update memo and genre separately since BookRecord doesn't have memo field directly
        try fixture.db.insertBook(BookRecord(
            id: 0, title: "Memo", genre: "G", dateAdded: Date(),
            keywordA: "kw2"
        ))
        // Use the first inserted book and verify what was stored
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/detail", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .ok)
                let d = try dec().decode(BookDetailDTO.self, from: Data(buffer: resp.body))
                #expect(d.keywordA == "kw")
                #expect(d.title == "Full")
            }
        }
    }

    /// 4.2c-6b: detail は path を秘匿しつつ fileExtension（リモート「ファイル形式」表示用）を返す。
    @Test func bookDetailReturnsFileExtension() async throws {
        let fixture = try TestLibraryFixture(name: "Ext", bookCount: 0)
        defer { fixture.cleanup() }
        let id = try fixture.addRealBook(zipFixtureNamed: "three_pages")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/detail", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .ok)
                let d = try dec().decode(BookDetailDTO.self, from: Data(buffer: resp.body))
                #expect(d.fileExtension == "zip")
                #expect(d.path == nil)   // path 自体は秘匿
            }
        }
    }

    @Test func facetsReturnsDistinctGenres() async throws {
        let fixture = try TestLibraryFixture(name: "Fc", bookCount: 0)
        defer { fixture.cleanup() }
        _ = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "A", genre: "SF", dateAdded: Date()))
        _ = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "B", genre: "SF", dateAdded: Date()))
        _ = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "C", genre: "Fantasy", dateAdded: Date()))
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/facets/genre", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .ok)
                let vals = try dec().decode([String].self, from: Data(buffer: resp.body))
                #expect(Set(vals) == Set(["SF", "Fantasy"]))
            }
        }
    }

    // MARK: - SQL injection prevention (4.2b-1b-2b)

    @Test func facetsRejectsUnknownColumn() async throws {
        let fixture = try TestLibraryFixture(name: "FcBad", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])).buildApplication()
        try await app.test(.router) { client in
            // SQL-injection-ish / unknown column → 400
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/facets/title);DROP", method: .get,
                headers: [.authorization: "Bearer tk"]) { resp in
                #expect(resp.status == .badRequest)
            }
        }
    }

    @Test func booksRejectsUnknownBrowseColumn() async throws {
        let fixture = try TestLibraryFixture(name: "BfBad", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let badBrowse = String(data: try JSONEncoder().encode([BrowseConstraint(column: "evil; DROP TABLE book", value: "x")]), encoding: .utf8)!
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let app = LibraryServerCore(config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books?browse=\(badBrowse)", method: .get,
                headers: [.authorization: "Bearer tk"]) { resp in
                #expect(resp.status == .badRequest)
            }
        }
    }

    @Test func booksScopeShelfFiltersToShelfMembers() async throws {
        let fixture = try TestLibraryFixture(name: "Scope", bookCount: 0)
        defer { fixture.cleanup() }
        let inShelf = try fixture.db.insertBookReturningID(BookRecord(id: 0, title: "InShelf", dateAdded: Date()))
        _ = try fixture.db.insertBookReturningID(BookRecord(id: 0, title: "NotInShelf", dateAdded: Date()))
        let shelfID = try fixture.db.createUserShelf(title: "MyShelf")
        try fixture.db.appendBooksToShelf(playlistID: shelfID, bookIDs: [inShelf])
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books?scope=shelf&scopeId=\(shelfID)", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .ok)
                let page = try dec().decode(BookPageDTO.self, from: Data(buffer: resp.body))
                #expect(page.items.contains { $0.title == "InShelf" })
                #expect(!page.items.contains { $0.title == "NotInShelf" })
            }
        }
    }

    @Test func booksFilterByBookTypeViaJSON() async throws {
        let fixture = try TestLibraryFixture(name: "Bf", bookCount: 0)
        defer { fixture.cleanup() }
        _ = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "t0", dateAdded: Date(), bookType: 0))
        _ = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "t1", dateAdded: Date(), bookType: 1))
        let lib = fixture.servedLibrary()
        var fs = FilterState()
        fs.bookTypes = [1]
        let filterJSON = String(data: try JSONEncoder().encode(fs), encoding: .utf8)!
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books?filter=\(filterJSON)", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .ok)
                let page = try dec().decode(BookPageDTO.self, from: Data(buffer: resp.body))
                #expect(page.total == 1)
                #expect(page.items.first?.title == "t1")
            }
        }
    }
}
