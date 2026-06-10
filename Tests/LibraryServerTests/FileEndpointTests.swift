// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("File endpoint")
struct FileEndpointTests {
    @Test func fileReturnsOriginalBytes() async throws {
        let fixture = try TestLibraryFixture(name: "F", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/file", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .ok)
                // zip マジック PK\x03\x04
                #expect(Data(buffer: response.body).prefix(2) == Data([0x50, 0x4B]))
                #expect(response.headers[.eTag] != nil)
                #expect(response.headers[.contentType] == "application/octet-stream")
            }
        }
    }

    /// path がディスク上に存在しない本 → 404（ダミー path の本）。
    @Test func missingFileIs404() async throws {
        let fixture = try TestLibraryFixture(name: "F2", bookCount: 1)   // path nil/不在の本
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/file", method: .get,
                headers: [.authorization: "Bearer tk"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
