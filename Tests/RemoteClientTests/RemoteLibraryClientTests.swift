// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient
import LibraryServerAPI

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

@Suite("RemoteLibraryClient", .serialized)
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
