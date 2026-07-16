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

        /// G4b stale 修正: 表紙は差し替わり得るのに GET cover は `immutable` 長期キャッシュ
        /// のため、共有 URLCache が古い表紙を返し続ける（ライブラリ開き直しまで解消しない）。
        /// L1/L2 が前段にあり URLSession 到達＝キャッシュミス＝新バイトが欲しい時なので、
        /// cover 取得は URLCache をバイパス（.reloadIgnoringLocalCacheData）して常に再取得する。
        @Test func coverDataBypassesURLCache() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: Data([0xFF, 0xD8, 0xFF]))
            let client = makeClient()
            _ = try await client.coverData(libraryUUID: "u1", bookID: 7, maxw: 600, libraryToken: "LT")
            let req = StubURLProtocol.lastRequest
            #expect(req?.url?.path == "/api/v1/libraries/u1/books/7/cover")
            #expect(req?.cachePolicy == .reloadIgnoringLocalCacheData)
        }

        /// 逆側の保証: 通常エンドポイントは既定ポリシーのまま（cover 以外に影響させない）。
        @Test func nonCoverRequestUsesDefaultCachePolicy() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(BookPageDTO(items: [], total: 0, page: 1, perPage: 100)))
            let client = makeClient()
            _ = try await client.fetchBooks(libraryUUID: "u1", query: nil as String?, sort: "title", ascending: true, page: 1, per: 100, libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.cachePolicy == .useProtocolCachePolicy)
        }

        // MARK: - G12b-2: 取り込み設定 / ロック / シェルフ membership / 重複スキャン

        @Test func getImportConfigDecodes() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:],
                body: try enc().encode(ImportConfigDTO(autoClassifyEnabled: true, thickBookThreshold: 40)))
            let dto = try await makeClient().getImportConfig(libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "GET")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/import-config") == true)
            #expect(dto.autoClassifyEnabled == true)
            #expect(dto.thickBookThreshold == 40)
        }
        @Test func putImportConfigSendsBody() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:],
                body: try enc().encode(ImportConfigDTO(autoClassifyEnabled: false, thickBookThreshold: nil)))
            _ = try await makeClient().putImportConfig(
                ImportConfigDTO(autoClassifyEnabled: false, thickBookThreshold: nil),
                libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "PUT")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/import-config") == true)
        }
        @Test func setLockPostsPassword() async throws {
            StubURLProtocol.stub = .init(status: 204, headers: [:], body: Data())
            try await makeClient().setLock(password: "pw", libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/lock") == true)
        }
        @Test func clearLockDeletes() async throws {
            StubURLProtocol.stub = .init(status: 204, headers: [:], body: Data())
            try await makeClient().clearLock(libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "DELETE")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/lock") == true)
        }
        @Test func addBooksToShelfPosts() async throws {
            StubURLProtocol.stub = .init(status: 204, headers: [:], body: Data())
            try await makeClient().addBooksToShelf(shelfID: 7, bookIDs: [1, 2], libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/shelves/7/books") == true)
        }
        @Test func removeBooksFromShelfDeletes() async throws {
            StubURLProtocol.stub = .init(status: 204, headers: [:], body: Data())
            try await makeClient().removeBooksFromShelf(shelfID: 7, bookIDs: [1], libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "DELETE")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/shelves/7/books") == true)
        }
        @Test func scanDuplicatesDecodes() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:],
                body: try enc().encode(DuplicateScanReply(exact: [], possible: [], candidateCount: 3, hashedCount: 3, missingCount: 0)))
            let reply = try await makeClient().scanDuplicates(libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/duplicates/scan") == true)
            #expect(reply.candidateCount == 3)
            // 大規模ライブラリでサーバ側処理が長いため、短い既定タイムアウト(10s)ではなく長めであること。
            #expect((StubURLProtocol.lastRequest?.timeoutInterval ?? 0) > 15)
        }

        @Test func fetchCountsDecodes() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:],
                body: try enc().encode(LibraryCountsDTO(libraryTotal: 42, recentCount: 7, recentDays: 30)))
            let dto = try await makeClient().fetchCounts(libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "GET")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/counts") == true)
            #expect(dto.libraryTotal == 42)
            #expect(dto.recentCount == 7)
            #expect(dto.recentDays == 30)
        }

        // MARK: - G12b-3a: 一般設定・保守・scan-now

        @Test func generalSettingsClientRoundTrip() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:],
                body: try enc().encode(GeneralSettingsDTO(displayName: "L", backupEnabled: true, backupGenerations: 4)))
            let dto = try await makeClient().fetchGeneralSettings(libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/general-settings") == true)
            #expect(dto.backupGenerations == 4)
        }
        @Test func integrityClientDecodes() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:],
                body: try enc().encode(IntegrityCheckDTO(healthy: true, rows: ["ok"])))
            let dto = try await makeClient().checkIntegrity(libraryUUID: "U", libraryToken: "LT")
            #expect(StubURLProtocol.lastRequest?.httpMethod == "GET")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/integrity-check") == true)
            #expect(dto.healthy == true)
        }
        @Test func scanNowSendsPOST() async throws {
            StubURLProtocol.stub = .init(status: 204, headers: [:], body: Data())
            try await makeClient().scanWatchedFoldersNow(libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/watch/scan-now") == true)
        }

        // MARK: - G12b-3b: メンテナンス（メタ補完/表紙圧縮・非同期ジョブ）

        @Test func startCompleteMetadataAcceptedDoesNotThrow() async throws {
            StubURLProtocol.stub = .init(status: 202, headers: [:], body: Data())
            try await makeClient().startCompleteMetadata(libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/maintenance/complete-metadata") == true)
        }
        @Test func startCompleteMetadataForbiddenThrows() async throws {
            StubURLProtocol.stub = .init(status: 403, headers: [:], body: Data())
            await #expect(throws: RemoteClientError.forbidden) {
                try await makeClient().startCompleteMetadata(libraryUUID: "U", libraryToken: nil)
            }
        }
        @Test func startCompleteMetadataBusyThrowsServer409() async throws {
            StubURLProtocol.stub = .init(status: 409, headers: [:], body: Data())
            await #expect(throws: RemoteClientError.server(409)) {
                try await makeClient().startCompleteMetadata(libraryUUID: "U", libraryToken: nil)
            }
        }
        @Test func startCompressCoversSendsPOST() async throws {
            StubURLProtocol.stub = .init(status: 202, headers: [:], body: Data())
            try await makeClient().startCompressCovers(libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/maintenance/compress-covers") == true)
        }
        @Test func cancelMaintenanceSendsPOST() async throws {
            StubURLProtocol.stub = .init(status: 202, headers: [:], body: Data())
            try await makeClient().cancelMaintenance(libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/maintenance/cancel") == true)
        }

        // MARK: - G12b-2c: 監視フォルダ設定

        @Test func fetchWatchConfigDecodes() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:],
                body: try enc().encode(WatchConfigDTO(enabled: true,
                    folders: [WatchedFolderDTO(id: "f1", path: "/x", enabled: true, subfolderMode: .recurse)],
                    presets: [FilenameFormatPresetDTO(id: "p1", name: "コミック")])))
            let dto = try await makeClient().fetchWatchConfig(libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "GET")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/watch-config") == true)
            #expect(dto.folders.first?.subfolderMode == .recurse)
            #expect(dto.presets?.first?.id == "p1")
        }

        @Test func putWatchConfigSendsPUT() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:],
                body: try enc().encode(WatchConfigDTO(enabled: false, folders: [])))
            _ = try await makeClient().putWatchConfig(
                WatchConfigDTO(enabled: false, folders: []), libraryUUID: "U", libraryToken: "LT")
            #expect(StubURLProtocol.lastRequest?.httpMethod == "PUT")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/watch-config") == true)
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Library-Token") == "LT")
        }

        // MARK: - G12b-3c: 命名プリセット

        @Test func fetchPresetsDecodes() async throws {
            let set = PresetSetDTO(presets: [FilenameFormatPresetDTO(id: "a", name: "A", format: "@title")], defaultID: "a")
            StubURLProtocol.stub = .init(status: 200, headers: ["Content-Type": "application/json"], body: try enc().encode(set))
            let got = try await makeClient().fetchPresets(libraryUUID: "L", libraryToken: nil)
            #expect(got.defaultID == "a")
            #expect(got.presets.first?.format == "@title")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/presets") == true)
        }

        @Test func putPresetsSendsPUT() async throws {
            let set = PresetSetDTO(presets: [FilenameFormatPresetDTO(id: "a", name: "A", format: "@title")], defaultID: "a")
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(set))
            _ = try await makeClient().putPresets(set, libraryUUID: "L", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "PUT")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/L/presets") == true)
        }

        // MARK: - G12b-3c: 既存フォルダ再取込み

        @Test func importExistingAcceptedDoesNotThrow() async throws {
            StubURLProtocol.stub = .init(status: 202, headers: [:], body: Data())
            try await makeClient().importExistingInWatchedFolder(folderID: "f1", libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/watch/import-existing") == true)
        }
        @Test func importExistingNoContentDoesNotThrow() async throws {
            StubURLProtocol.stub = .init(status: 204, headers: [:], body: Data())
            try await makeClient().importExistingInWatchedFolder(folderID: "f1", libraryUUID: "U", libraryToken: nil)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(StubURLProtocol.lastRequest?.url?.path.hasSuffix("/libraries/U/watch/import-existing") == true)
        }
        @Test func importExistingForbiddenThrows() async throws {
            StubURLProtocol.stub = .init(status: 403, headers: [:], body: Data())
            await #expect(throws: RemoteClientError.forbidden) {
                try await makeClient().importExistingInWatchedFolder(folderID: "f1", libraryUUID: "U", libraryToken: nil)
            }
        }

        /// G14 follow-up: 非 SSE リクエストは有限の短いタイムアウトを持つこと。
        /// 既定の 60s だと、サーバ不達時に runLiveSync の reload が最長 60s ハングし、
        /// サーバ復帰後もそのリクエストが返るまで再接続を試せず赤字の復帰が ~40s まで遅れる。
        @Test func nonSSERequestsUseBoundedTimeout() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:],
                body: try enc().encode(BookPageDTO(items: [], total: 0, page: 1, perPage: 100)))
            _ = try await makeClient().fetchBooks(libraryUUID: "u1", query: nil, sort: "title",
                ascending: true, page: 1, per: 100, libraryToken: nil)
            let t = try #require(StubURLProtocol.lastRequest?.timeoutInterval)
            #expect(t > 0 && t <= 15)   // 既定 60s を排除。SSE(12s) と揃う短いアイドルタイムアウト
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
        @Test func bookFileReturnsBytes() async throws {
            let bytes = Data([0x50, 0x4B, 0x03, 0x04])
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: bytes)
            let data = try await makeClient().bookFile(libraryUUID: "u", bookID: 9, libraryToken: "LT")
            #expect(data == bytes)
            #expect(StubURLProtocol.lastRequest?.url?.path == "/api/v1/libraries/u/books/9/file")
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Library-Token") == "LT")
        }

        @Test func adjacentVolumeReturnsDTO() async throws {
            let book = BookListItemDTO(id: 43, title: "Vol 3", author: "Author", series: "S",
                                       volume: 3.0, rating: 0, unseen: false, bookType: 0,
                                       pages: nil, lastPage: nil, lastReadAt: nil,
                                       dateAdded: Date(timeIntervalSince1970: 0),
                                       hasCover: false, coverVersion: nil)
            let reply = AdjacentVolumeReply(book: book)
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(reply))
            let dto = try await makeClient().adjacentVolume(libraryUUID: "u", bookID: 42, direction: "next", libraryToken: nil)
            #expect(dto?.id == 43)
            let url = StubURLProtocol.lastRequest?.url
            #expect(url?.path == "/api/v1/libraries/u/books/42/adjacent")
            #expect(url?.query?.contains("dir=next") == true)
        }

        @Test func adjacentVolumeNoneReturnsNil() async throws {
            let reply = AdjacentVolumeReply(book: nil)
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(reply))
            let dto = try await makeClient().adjacentVolume(libraryUUID: "u", bookID: 42, direction: "prev", libraryToken: "LT")
            #expect(dto == nil)
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Library-Token") == "LT")
        }

        @Test func meReturnsReplyWithTier() async throws {
            let reply = MeReply(tier: .admin, scope: .all)
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(reply))
            let me = try await makeClient().me(libraryToken: "LT")
            #expect(me.tier == .admin)
            #expect(me.role == .write)
            #expect(StubURLProtocol.lastRequest?.url?.path == "/api/v1/me")
            #expect(StubURLProtocol.lastRequest?.httpMethod == "GET")
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Library-Token") == "LT")
        }

        @Test func deleteBookDBOnlySendsDeleteNoTrashQuery() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: Data())
            try await makeClient().deleteBook(libraryUUID: "U", bookID: 7, trash: false, libraryToken: "LT")
            let url = StubURLProtocol.lastRequest!.url!
            #expect(url.path == "/api/v1/libraries/U/books/7")
            #expect(url.query?.contains("trash") != true)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "DELETE")
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Library-Token") == "LT")
        }

        @Test func deleteBookTrashAddsQuery() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: Data())
            try await makeClient().deleteBook(libraryUUID: "U", bookID: 7, trash: true, libraryToken: nil)
            let url = StubURLProtocol.lastRequest!.url!
            #expect(url.path == "/api/v1/libraries/U/books/7")
            #expect(url.query?.contains("trash=1") == true)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "DELETE")
        }

        @Test func deleteBookForbiddenThrows() async throws {
            StubURLProtocol.stub = .init(status: 403, headers: [:], body: Data())
            await #expect(throws: RemoteClientError.forbidden) {
                try await makeClient().deleteBook(libraryUUID: "U", bookID: 7, trash: false, libraryToken: nil)
            }
        }

        @Test func updateBookReturnsUpdatedDetail() async throws {
            let detail = BookDetailDTO(id: 42, title: "NEW", author: nil, genre: nil, path: nil,
                dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 0,
                pages: nil, rating: 0, unseen: false, keywordA: nil, keywordB: nil, keywordC: nil,
                neta: nil, memo: nil, series: nil, volume: nil,
                coverImageName: nil, coverCropRectJSON: nil, pageDirection: nil)
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(detail))
            let patch = BookPatchDTO(title: "NEW")
            let got = try await makeClient().updateBook(libraryUUID: "U", bookID: 42, patch: patch, libraryToken: "LT")
            #expect(got.title == "NEW")
            #expect(StubURLProtocol.lastRequest?.url?.path == "/api/v1/libraries/U/books/42")
            #expect(StubURLProtocol.lastRequest?.httpMethod == "PATCH")
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Library-Token") == "LT")
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }

        @Test func updateBookForbiddenThrows() async throws {
            StubURLProtocol.stub = .init(status: 403, headers: [:], body: Data())
            let patch = BookPatchDTO()
            await #expect(throws: RemoteClientError.forbidden) {
                _ = try await makeClient().updateBook(libraryUUID: "U", bookID: 42, patch: patch, libraryToken: nil as String?)
            }
        }

        @Test func setCoverImagePutsBytesToEndpoint() async throws {
            let detail = BookDetailDTO(id: 9, title: "T", author: nil, genre: nil, path: nil,
                dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 0,
                pages: nil, rating: 0, unseen: false, keywordA: nil, keywordB: nil, keywordC: nil,
                neta: nil, memo: nil, series: nil, volume: nil,
                coverImageName: "@external", coverCropRectJSON: nil, pageDirection: nil)
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try enc().encode(detail))
            _ = try await makeClient().setCoverImage(libraryUUID: "u", bookID: 9,
                imageData: Data([0xFF, 0xD8, 1, 2]), cropJSON: "{\"x\":0,\"y\":0,\"w\":1,\"h\":1}", libraryToken: nil)
            let req = StubURLProtocol.lastRequest
            #expect(req?.httpMethod == "PUT")
            #expect(req?.url?.path == "/api/v1/libraries/u/books/9/cover-image")
            #expect(req?.url?.query?.contains("crop=") == true)
            #expect(req?.value(forHTTPHeaderField: "Content-Type")?.contains("image") == true)
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
            let content = RemoteBookContent(client: client(), serverID: UUID(), libraryUUID: "u", bookID: 1, libraryToken: nil, maxWidth: 1600, cache: nil)
            let n = try await content.pageCount
            #expect(n == 42)
        }

        @Test func imageDataFetchesPageWithMaxw() async throws {
            let bytes = Data([0xFF, 0xD8, 0x01, 0x02])
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: bytes)
            let content = RemoteBookContent(client: client(), serverID: UUID(), libraryUUID: "u", bookID: 9, libraryToken: nil, maxWidth: 1600, cache: nil)
            let data = try await content.imageData(at: 3)
            #expect(data == bytes)
            let url = StubURLProtocol.lastRequest?.url
            #expect(url?.path == "/api/v1/libraries/u/books/9/pages/3")
            #expect(url?.query?.contains("maxw=1600") == true)
        }
    }

    @Suite("RemoteLibraryClient events (G8a/G14)")
    struct RemoteLibraryClientEventsTests {
        private func makeClient() -> RemoteLibraryClient {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [StubURLProtocol.self]
            let session = URLSession(configuration: cfg)
            return RemoteLibraryClient(baseURL: URL(string: "http://h:8080/")!, deviceToken: "dtok", session: session)
        }

        /// G14: SSE ストリーミングリクエストは無期限タイムアウトではなく、
        /// サーバの短縮ハートビート(5s)より少し長い有限アイドルタイムアウト(12s)を持つこと。
        /// 無期限のままだと Tailscale 経由でダウンしたサーバへの再接続が OS の TCP connect
        /// タイムアウト(~60s)までハングし、赤字バナーの自動復帰が遅延する。
        @Test func eventsRequestUsesFiniteTimeout() async throws {
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: Data())
            let client = makeClient()
            let stream = client.events(libraryToken: nil)
            for try await _ in stream { break }   // 最初の .connected を受けたら打ち切り、リクエストが発行済みであることを保証
            #expect(StubURLProtocol.lastRequest?.timeoutInterval == 12)
            #expect(StubURLProtocol.lastRequest?.timeoutInterval != .infinity)
        }
    }
}
