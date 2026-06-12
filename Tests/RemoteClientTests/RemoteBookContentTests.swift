// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient
import LibraryServerAPI
import AppCore

@Suite("RemoteBookContent — BookContent 適合", .serialized)
struct RemoteBookContentTests {
    private func client() -> RemoteLibraryClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return RemoteLibraryClient(baseURL: URL(string: "http://h:8080/")!, deviceToken: "d",
                                   session: URLSession(configuration: cfg))
    }
    private func enc() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }

    @Test func pageCountFromManifest() async throws {
        StubURLProtocol.stub = .init(status: 200, headers: [:],
            body: try enc().encode(ManifestDTO(pageCount: 42, direction: "rtl", format: "archive", etag: "e")))
        let content = RemoteBookContent(client: client(), libraryUUID: "u", bookID: 1, libraryToken: nil, maxWidth: 1600)
        let n = try await content.pageCount
        #expect(n == 42)
    }

    @Test func imageDataFetchesPageWithMaxw() async throws {
        let bytes = Data([0xFF, 0xD8, 0x01, 0x02])
        StubURLProtocol.stub = .init(status: 200, headers: [:], body: bytes)
        let content = RemoteBookContent(client: client(), libraryUUID: "u", bookID: 9, libraryToken: nil, maxWidth: 1600)
        let data = try await content.imageData(at: 3)
        #expect(data == bytes)
        let url = StubURLProtocol.lastRequest?.url
        #expect(url?.path == "/api/v1/libraries/u/books/9/pages/3")
        #expect(url?.query?.contains("maxw=1600") == true)
    }
}
