// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer

@Suite("POST /books/:id/epub-progress endpoint")
struct EPUBProgressEndpointTests {
    // MARK: - helpers

    private func decodeDetail(_ buffer: ByteBuffer) throws -> BookDetailDTO {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookDetailDTO.self, from: Data(buffer: buffer))
    }

    // MARK: - 正常系

    /// POST → 200、後続の GET /detail で epubLocator が同じ値・unseen が false になる。
    @Test func postEPUBProgressUpdatesDetailAndMarksRead() async throws {
        let fixture = try TestLibraryFixture(name: "EPUBProg1", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addUnsupportedFormatBook(extension: "epub")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/epub-progress", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"spine":2,"progress":0.4,"engine":"foliate"}"#)
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/detail", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let detail = try decodeDetail(response.body)
                #expect(detail.epubLocator == EPUBLocatorDTO(spine: 2, progress: 0.4, cfi: nil, engine: "foliate"))
                #expect(detail.unseen == false)
            }
        }
    }

    /// progress が範囲外（2.0）でも 400 にせず 1 に丸まる（値型が丸める）。
    @Test func postEPUBProgressClampsOutOfRangeProgress() async throws {
        let fixture = try TestLibraryFixture(name: "EPUBProg2", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addUnsupportedFormatBook(extension: "epub")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/epub-progress", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"spine":1,"progress":2.0}"#)
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/detail", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let detail = try decodeDetail(response.body)
                #expect(detail.epubLocator?.progress == 1.0)
            }
        }
    }

    /// 負の spine は 0 に丸まる。
    @Test func postEPUBProgressClampsNegativeSpine() async throws {
        let fixture = try TestLibraryFixture(name: "EPUBProg3", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addUnsupportedFormatBook(extension: "epub")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/epub-progress", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"spine":-3,"progress":0.1}"#)
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/detail", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                let detail = try decodeDetail(response.body)
                #expect(detail.epubLocator?.spine == 0)
            }
        }
    }

    // MARK: - 異常系

    /// 認証なし → 401。
    @Test func noAuthIs401() async throws {
        let fixture = try TestLibraryFixture(name: "EPUBProg4", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/epub-progress", method: .post,
                body: .init(string: #"{"spine":0,"progress":0.0}"#)
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    /// 存在しない book id → 404。
    @Test func unknownBookIs404() async throws {
        let fixture = try TestLibraryFixture(name: "EPUBProg5", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/999/epub-progress", method: .post,
                headers: [.authorization: "Bearer tk"],
                body: .init(string: #"{"spine":0,"progress":0.0}"#)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
