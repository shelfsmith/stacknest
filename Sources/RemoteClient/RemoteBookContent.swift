// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryServerAPI

/// リモートサーバの 1 冊を BookContent として供給する。既存 ViewerWindowController が
/// そのまま使える（pageCount=manifest / imageData=GET /pages/:n?maxw=）。
public struct RemoteBookContent: BookContent {
    private let client: RemoteLibraryClient
    private let serverID: UUID
    private let libraryUUID: String
    private let bookID: Int
    private let libraryToken: String?
    private let maxWidth: Int?
    private let cache: RemotePageCache?

    public init(client: RemoteLibraryClient, serverID: UUID, libraryUUID: String, bookID: Int,
                libraryToken: String?, maxWidth: Int?, cache: RemotePageCache? = .shared) {
        self.client = client
        self.serverID = serverID
        self.libraryUUID = libraryUUID
        self.bookID = bookID
        self.libraryToken = libraryToken
        self.maxWidth = maxWidth
        self.cache = cache
    }

    public var pageCount: Int {
        get async throws {
            try await client.manifest(libraryUUID: libraryUUID, bookID: bookID, libraryToken: libraryToken).pageCount
        }
    }

    public func imageData(at page: Int) async throws -> Data {
        let client = self.client, uuid = self.libraryUUID, bid = self.bookID
        let token = self.libraryToken, mw = self.maxWidth
        let fetch: @Sendable () async throws -> Data = {
            try await client.pageData(libraryUUID: uuid, bookID: bid, index: page, maxw: mw, libraryToken: token)
        }
        guard let cache else { return try await fetch() }
        let key = RemotePageCache.Key(serverID: serverID, libraryUUID: uuid, bookID: bid, kind: .page, page: page, maxw: mw)
        return try await cache.data(for: key, fetch: fetch)
    }
}
