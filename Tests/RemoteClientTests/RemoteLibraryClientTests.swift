// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient
import LibraryServerAPI
import AppCore
import LibraryStore

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub { let status: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var stub: Stub?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        Self.lastRequest = request
        let s = Self.stub ?? Stub(status: 200, headers: [:], body: Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: s.status,
                                   httpVersion: "HTTP/1.1", headerFields: s.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: s.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("RemoteClient (stub-backed)", .serialized)
struct StubBackedRemoteClientTests {

    @Suite("RemoteLibraryClient")
    struct RemoteLibraryClientTests {
        private func makeClient() -> RemoteLibraryClient {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [StubURLProtocol.self]
            let session = URLSession(configuration: cfg)
            return RemoteLibraryClient(baseURL: URL(string: "http://h:8080/")!, deviceToken: "dtok", session: session)
        }
        private func enc() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }

        @Test func listLibrariesDecodesAndSendsBearer() async throws {
            let libs = [LibraryDTO(id: "u1", name: "L1", locked: false, bookCount: 3)]
            StubURLProtocol.stub = .init(status: 200, headers: ["Content-Type": "application/json"], body: try enc().encode(libs))
            let client = makeClient()
            let got = try await client.listLibraries()
            #expect(got.first?.id == "u1")
            let req = StubURLProtocol.lastRequest
            #expect(req?.url?.path == "/api/v1/libraries")
            #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer dtok")
        }

        @Test func fetchBooksBuildsQuery() async throws {
            let page = BookPageDTO(items: [], total: 0, page: 2, perPage: 50)
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(page))
            let client = makeClient()
            _ = try await client.fetchBooks(libraryUUID: "u1", query: "abc", sort: "title", ascending: false, page: 2, per: 50, libraryToken: nil)
            let comps = URLComponents(url: StubURLProtocol.lastRequest!.url!, resolvingAgainstBaseURL: false)!
            let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(comps.path == "/api/v1/libraries/u1/books")
            #expect(items["q"] == "abc")
            #expect(items["sort"] == "title")
            #expect(items["order"] == "desc")
            #expect(items["page"] == "2")
            #expect(items["per"] == "50")
        }

        @Test func unlockSendsPasswordAndReturnsToken() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(UnlockReply(libraryToken: "lt")))
            let client = makeClient()
            let tok = try await client.unlock(libraryUUID: "u1", password: "pw")
            #expect(tok == "lt")
            #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
        }

        @Test func forbiddenMapsTo403Error() async throws {
            StubURLProtocol.stub = .init(status: 403, headers: [:], body: Data())
            let client = makeClient()
            await #expect(throws: RemoteClientError.forbidden) {
                _ = try await client.unlock(libraryUUID: "u1", password: "bad")
            }
        }

        @Test func libraryTokenHeaderSentWhenProvided() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(BookPageDTO(items: [], total: 0, page: 1, perPage: 100)))
            let client = makeClient()
            _ = try await client.fetchBooks(libraryUUID: "u1", query: nil as String?, sort: "title", ascending: true, page: 1, per: 100, libraryToken: "LTOK")
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Library-Token") == "LTOK")
        }
    }

    @Suite("RemoteLibraryClient browse")
    struct RemoteBrowseClientTests {
        private func makeClient() -> RemoteLibraryClient {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [StubURLProtocol.self]
            return RemoteLibraryClient(baseURL: URL(string: "http://h:8080/")!, deviceToken: "d",
                                       session: URLSession(configuration: cfg))
        }
        private func enc() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }

        @Test func listShelvesDecodes() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:],
                body: try enc().encode([ShelfDTO(id: 3, title: "S", kind: "user", isSmart: false)]))
            let got = try await makeClient().listShelves(libraryUUID: "u", libraryToken: nil)
            #expect(got.first?.id == 3)
            #expect(StubURLProtocol.lastRequest?.url?.path == "/api/v1/libraries/u/shelves")
        }
        @Test func facetValuesBuildsScopeAndFilterParams() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(["SF"]))
            var fs = FilterState(); fs.bookTypes = [1]
            _ = try await makeClient().facetValues(libraryUUID: "u", field: "genre",
                scope: "shelf", scopeId: 7, recentDays: nil, filter: fs,
                browse: [BrowseConstraint(column: "author", value: "X")], q: "k", libraryToken: "LT")
            let comps = URLComponents(url: StubURLProtocol.lastRequest!.url!, resolvingAgainstBaseURL: false)!
            let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(comps.path == "/api/v1/libraries/u/facets/genre")
            #expect(items["scope"] == "shelf"); #expect(items["scopeId"] == "7"); #expect(items["q"] == "k")
            #expect(items["filter"]?.isEmpty == false); #expect(items["browse"]?.isEmpty == false)
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Library-Token") == "LT")
        }
        @Test func bookDetailDecodes() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(
                BookDetailDTO(id: 9, title: "T", author: nil, genre: "G", path: nil, dateAdded: Date(timeIntervalSince1970: 0),
                    playDate: nil, bookType: 0, fileType: 2, pages: nil, rating: 0, unseen: true,
                    keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil, series: nil, volume: nil,
                    coverImageName: nil, coverCropRectJSON: nil, pageDirection: nil)))
            let d = try await makeClient().bookDetail(libraryUUID: "u", bookID: 9, libraryToken: nil)
            #expect(d.genre == "G")
            #expect(StubURLProtocol.lastRequest?.url?.path == "/api/v1/libraries/u/books/9/detail")
        }
    }

    @Suite("RemoteBookContent — BookContent 適合")
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
}
