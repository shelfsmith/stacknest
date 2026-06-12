// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI

/// 別 StackNest サーバの HTTP API を叩くクライアント（メタ=JSON 共有 DTO / バイナリ=Data）。
public struct RemoteLibraryClient: Sendable {
    public let baseURL: URL
    public let deviceToken: String
    private let session: URLSession

    public init(baseURL: URL, deviceToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.deviceToken = deviceToken
        self.session = session
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    private func makeURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/v1").appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    private func request(_ url: URL, method: String = "GET", libraryToken: String? = nil,
                         body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        if let libraryToken { req.setValue(libraryToken, forHTTPHeaderField: "X-Library-Token") }
        if let body { req.httpBody = body }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw RemoteClientError.badResponse }
            switch http.statusCode {
            case 200...299: return data
            case 401: throw RemoteClientError.unauthorized
            case 403: throw RemoteClientError.forbidden
            case 404: throw RemoteClientError.notFound
            default: throw RemoteClientError.server(http.statusCode)
            }
        } catch let e as RemoteClientError {
            throw e
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw RemoteClientError.timeout
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                throw RemoteClientError.offline
            default: throw RemoteClientError.server(-1)
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try Self.decoder().decode(T.self, from: data) }
        catch { throw RemoteClientError.decoding }
    }

    // MARK: - API

    public func serverInfo() async throws -> ServerCapabilities {
        let data = try await send(request(baseURL.appendingPathComponent("api/v1/server/info")))
        return try decode(ServerCapabilities.self, data)
    }

    public func listLibraries() async throws -> [LibraryDTO] {
        try decode([LibraryDTO].self, try await send(request(makeURL("libraries"))))
    }

    public func unlock(libraryUUID: String, password: String) async throws -> String {
        let body = try JSONEncoder().encode(["password": password])
        let url = makeURL("libraries/\(libraryUUID)/unlock")
        let data = try await send(request(url, method: "POST", body: body, contentType: "application/json"))
        return try decode(UnlockReply.self, data).libraryToken
    }

    public func fetchBooks(libraryUUID: String, query: String?, sort: String, ascending: Bool,
                           page: Int, per: Int, libraryToken: String?) async throws -> BookPageDTO {
        var q: [URLQueryItem] = [
            .init(name: "sort", value: sort),
            .init(name: "order", value: ascending ? "asc" : "desc"),
            .init(name: "page", value: String(page)),
            .init(name: "per", value: String(per)),
        ]
        if let query, !query.isEmpty { q.insert(.init(name: "q", value: query), at: 0) }
        let url = makeURL("libraries/\(libraryUUID)/books", query: q)
        return try decode(BookPageDTO.self, try await send(request(url, libraryToken: libraryToken)))
    }

    public func manifest(libraryUUID: String, bookID: Int, libraryToken: String?) async throws -> ManifestDTO {
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/manifest")
        return try decode(ManifestDTO.self, try await send(request(url, libraryToken: libraryToken)))
    }

    public func pageData(libraryUUID: String, bookID: Int, index: Int, maxw: Int?, libraryToken: String?) async throws -> Data {
        var q: [URLQueryItem] = []
        if let maxw, maxw > 0 { q.append(.init(name: "maxw", value: String(maxw))) }
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/pages/\(index)", query: q)
        return try await send(request(url, libraryToken: libraryToken))
    }

    public func coverData(libraryUUID: String, bookID: Int, maxw: Int?, libraryToken: String?) async throws -> Data {
        var q: [URLQueryItem] = []
        if let maxw, maxw > 0 { q.append(.init(name: "maxw", value: String(maxw))) }
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/cover", query: q)
        return try await send(request(url, libraryToken: libraryToken))
    }

    public func postProgress(libraryUUID: String, bookID: Int, page: Int, libraryToken: String?) async throws {
        let body = try JSONEncoder().encode(["page": page])
        let url = makeURL("libraries/\(libraryUUID)/books/\(bookID)/progress")
        _ = try await send(request(url, method: "POST", libraryToken: libraryToken, body: body, contentType: "application/json"))
    }
}
