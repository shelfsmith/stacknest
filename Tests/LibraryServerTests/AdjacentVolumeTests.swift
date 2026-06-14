// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import StackroomFormat
@testable import LibraryServer

@Suite("Adjacent volume endpoint (4.2b-4)")
struct AdjacentVolumeTests {

    // MARK: - Helpers

    private func dec() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 同一シリーズ "S" の vol1/vol2/vol3 を挿入した fixture を返す。
    /// 返り値は (fixture, app, libUUID, id1, id2, id3)。
    private func makeSeriesFixture() throws -> (TestLibraryFixture, some ApplicationProtocol, String, Int, Int, Int) {
        let fixture = try TestLibraryFixture(name: "Adj", bookCount: 0)
        let id1 = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "Vol1", dateAdded: Date(), series: "S", volume: 1))
        let id2 = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "Vol2", dateAdded: Date(), series: "S", volume: 2))
        let id3 = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "Vol3", dateAdded: Date(), series: "S", volume: 3))
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        return (fixture, app, lib.uuid, id1, id2, id3)
    }

    // MARK: - Tests

    /// next: vol2 → vol3 を返す。
    @Test func nextReturnHigherVolumeSibling() async throws {
        let (fixture, app, uuid, _, id2, id3) = try makeSeriesFixture()
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books/\(id2)/adjacent?dir=next",
                method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .ok)
                let reply = try dec().decode(AdjacentVolumeReply.self, from: Data(buffer: resp.body))
                let book = try #require(reply.book)
                #expect(book.id == id3)
                #expect(book.volume == 3)
            }
        }
    }

    /// prev: vol2 → vol1 を返す。
    @Test func prevReturnLowerVolumeSibling() async throws {
        let (fixture, app, uuid, id1, id2, _) = try makeSeriesFixture()
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books/\(id2)/adjacent?dir=prev",
                method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .ok)
                let reply = try dec().decode(AdjacentVolumeReply.self, from: Data(buffer: resp.body))
                let book = try #require(reply.book)
                #expect(book.id == id1)
                #expect(book.volume == 1)
            }
        }
    }

    /// 末尾巻で next → book == nil（常に 200）。
    @Test func noNextAtEndReturnsNilBook() async throws {
        let (fixture, app, uuid, _, _, id3) = try makeSeriesFixture()
        defer { fixture.cleanup() }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(uuid)/books/\(id3)/adjacent?dir=next",
                method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .ok)
                let reply = try dec().decode(AdjacentVolumeReply.self, from: Data(buffer: resp.body))
                #expect(reply.book == nil)
            }
        }
    }

    /// シリーズなし本 → book == nil（常に 200）。
    @Test func noSeriesBookReturnsNilBook() async throws {
        let fixture = try TestLibraryFixture(name: "AdjNS", bookCount: 0)
        defer { fixture.cleanup() }
        let id = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "Standalone", dateAdded: Date()))  // series == nil
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/adjacent?dir=next",
                method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .ok)
                let reply = try dec().decode(AdjacentVolumeReply.self, from: Data(buffer: resp.body))
                #expect(reply.book == nil)
            }
        }
    }

    /// 不正な dir パラメータ → 400。
    @Test func invalidDirReturns400() async throws {
        let fixture = try TestLibraryFixture(name: "AdjBad", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/adjacent?dir=foo",
                method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .badRequest)
            }
        }
    }

    /// lastPage: 進行状況が保存されている兄弟巻は lastPage を返す。
    @Test func lastPageFromViewerStateOfSibling() async throws {
        let fixture = try TestLibraryFixture(name: "AdjLP", bookCount: 0)
        defer { fixture.cleanup() }
        let id1 = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "Vol1", dateAdded: Date(), series: "S", volume: 1))
        let id2 = try fixture.db.insertBookReturningID(
            BookRecord(id: 0, title: "Vol2", dateAdded: Date(), series: "S", volume: 2))
        // vol1 の進行状況を保存（id2 から prev で id1 が返る）
        try fixture.db.saveViewerState(bookID: id1, spreadEnabled: false, coverOffset: false, lastPage: 42)
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id2)/adjacent?dir=prev",
                method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { resp in
                #expect(resp.status == .ok)
                let reply = try dec().decode(AdjacentVolumeReply.self, from: Data(buffer: resp.body))
                let book = try #require(reply.book)
                #expect(book.id == id1)
                #expect(book.lastPage == 42)
            }
        }
    }
}
