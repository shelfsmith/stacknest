// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer
@testable import LibraryStore

@Suite("rating endpoint (R 可・共有評価)")
struct RatingEndpointTests {
    private func makeApp(_ lib: ServedLibrary, editToken: String? = "W") -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: editToken),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
    }

    /// R トークンでもレートを更新できる（共有評価）。
    @Test func ratingAllowedForRead() async throws {
        let fixture = try TestLibraryFixture(name: "Rate1", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/rating",
                method: .post,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(string: #"{"rating":4}"#)
            ) { resp in #expect(resp.status == .ok) }
        }
        #expect(try fixture.db.fetchBook(id: 1)?.rating == 4)
    }

    /// 範囲外は 400。
    @Test func ratingOutOfRangeRejected() async throws {
        let fixture = try TestLibraryFixture(name: "Rate2", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/rating",
                method: .post,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(string: #"{"rating":9}"#)
            ) { resp in #expect(resp.status == .badRequest) }
        }
    }

    /// onBookChanged が発火する。
    @Test func ratingFiresBookChanged() async throws {
        let fixture = try TestLibraryFixture(name: "Rate3", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let box = RatingChangeBox()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W",
                          onBookChanged: { uuid, id in box.set("\(uuid)#\(id)") }),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/rating",
                method: .post,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(string: #"{"rating":3}"#)
            ) { resp in #expect(resp.status == .ok) }
        }
        #expect(box.value == "\(lib.uuid)#1")
    }
}

final class RatingChangeBox: @unchecked Sendable {
    private let lock = NSLock(); private var _v: String?
    func set(_ v: String) { lock.lock(); _v = v; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return _v }
}
