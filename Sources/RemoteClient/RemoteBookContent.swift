// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryServerAPI

/// リモートサーバの 1 冊を BookContent として供給する。既存 ViewerWindowController が
/// そのまま使える（pageCount=manifest / imageData=GET /pages/:n?maxw=）。
public struct RemoteBookContent: BookContent {
    private let client: RemoteLibraryClient
    private let libraryUUID: String
    private let bookID: Int
    private let libraryToken: String?
    private let maxWidth: Int?

    public init(client: RemoteLibraryClient, libraryUUID: String, bookID: Int,
                libraryToken: String?, maxWidth: Int?) {
        self.client = client
        self.libraryUUID = libraryUUID
        self.bookID = bookID
        self.libraryToken = libraryToken
        self.maxWidth = maxWidth
    }

    public var pageCount: Int {
        get async throws {
            try await client.manifest(libraryUUID: libraryUUID, bookID: bookID, libraryToken: libraryToken).pageCount
        }
    }

    public func imageData(at page: Int) async throws -> Data {
        try await client.pageData(libraryUUID: libraryUUID, bookID: bookID, index: page,
                                  maxw: maxWidth, libraryToken: libraryToken)
    }
}
