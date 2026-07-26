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
    /// G4d 層2: 実リクエスト回数を数える（version 差でキャッシュがミス→本当に再取得したかの確認用）。
    /// このスイートは .serialized なので、テスト間の逐次実行下で単純カウンタとして安全に使える。
    nonisolated(unsafe) static var requestCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        Self.lastRequest = request
        Self.requestCount += 1
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

        // MARK: - G23 Codex High #3: 逐次受信化の回帰
        //
        // `StubURLProtocol.stub` は static なグローバル状態なので、これらは
        // **`.serialized` なこのスイート内**に置く必要がある。別スイートへ出すと
        // 他テストと stub を奪い合い、他人の応答を読んでしまう（実際に一度そうなった）。

        /// 通常サイズの応答は影響を受けない（逐次受信化で壊れていないことの確認）。
        @Test func normalSizedResponseStillSucceedsAfterStreamingChange() async throws {
            let json = #"[{"id":"L1","name":"lib","locked":false,"bookCount":1}]"#
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: Data(json.utf8))
            let libs = try await makeClient().listLibraries()
            #expect(libs.count == 1)
            #expect(libs.first?.name == "lib")
        }

        /// チャンク境界（64KiB）をまたぐ応答でも欠落しない。
        @Test func responseAcrossChunkBoundaryIsIntact() async throws {
            // 64KiB を超える JSON を作る（name を長くする）。
            let filler = String(repeating: "あ", count: 30_000)   // UTF-8 で 90KB 相当
            let json = #"[{"id":"L1","name":"\#(filler)","locked":false,"bookCount":1}]"#
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: Data(json.utf8))
            let libs = try await makeClient().listLibraries()
            #expect(libs.first?.name.count == filler.count)
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
        /// G23 (M2): bookFile は一時ファイルへ書き出しその URL を返す（メモリに全量を載せない）。
        /// 旧・非進捗版（`-> Data`）は本番から使われていないため削除した。
        @Test func bookFileWritesTemporaryFileAndSendsLibraryToken() async throws {
            let bytes = Data([0x50, 0x4B, 0x03, 0x04])
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: bytes)
            let url = try await makeClient().bookFile(libraryUUID: "u", bookID: 9, libraryToken: "LT",
                                                      onProgress: nil, shouldCancel: nil)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try Data(contentsOf: url) == bytes)
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

        /// G12b-3c S5: サーバの DELETE 応答は復元用に BookRestoreDTO(200) を返すようになった。
        private func makeRestoreDTO(id: Int, title: String) -> BookRestoreDTO {
            BookRestoreDTO(id: id, title: title, author: nil, genre: nil, path: "/p",
                dateAdded: 0, playDate: nil, bookType: 0, fileType: 0, pages: nil,
                rating: 0, unseen: false, keywordA: nil, keywordB: nil, keywordC: nil,
                neta: nil, memo: nil, series: nil, volume: nil, coverImageName: nil)
        }

        @Test func deleteBookDBOnlySendsDeleteNoTrashQuery() async throws {
            let dto = makeRestoreDTO(id: 7, title: "T7")
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try JSONEncoder().encode(dto))
            let got = try await makeClient().deleteBook(libraryUUID: "U", bookID: 7, trash: false, libraryToken: "LT")
            #expect(got.id == 7)
            #expect(got.title == "T7")
            let url = StubURLProtocol.lastRequest!.url!
            #expect(url.path == "/api/v1/libraries/U/books/7")
            #expect(url.query?.contains("trash") != true)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "DELETE")
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Library-Token") == "LT")
        }

        @Test func deleteBookTrashAddsQuery() async throws {
            let dto = makeRestoreDTO(id: 7, title: "T7")
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try JSONEncoder().encode(dto))
            let got = try await makeClient().deleteBook(libraryUUID: "U", bookID: 7, trash: true, libraryToken: nil)
            #expect(got.id == 7)
            let url = StubURLProtocol.lastRequest!.url!
            #expect(url.path == "/api/v1/libraries/U/books/7")
            #expect(url.query?.contains("trash=1") == true)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "DELETE")
        }

        @Test func deleteBookForbiddenThrows() async throws {
            StubURLProtocol.stub = .init(status: 403, headers: [:], body: Data())
            await #expect(throws: RemoteClientError.forbidden) {
                _ = try await makeClient().deleteBook(libraryUUID: "U", bookID: 7, trash: false, libraryToken: nil)
            }
        }

        @Test func restoreBooksSendsPostToRestoreEndpoint() async throws {
            let dto = makeRestoreDTO(id: 9, title: "Restored")
            let result = RestoreResultDTO(restored: 1, requested: 1)
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: try JSONEncoder().encode(result))
            let got = try await makeClient().restoreBooks([dto], libraryUUID: "U", libraryToken: "LT")
            #expect(got.restored == 1)
            #expect(got.requested == 1)
            #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(StubURLProtocol.lastRequest?.url?.path == "/api/v1/libraries/U/books/restore")
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Library-Token") == "LT")
            #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
            if let sentBody = StubURLProtocol.lastRequest?.httpBody {
                let decoded = try JSONDecoder().decode([BookRestoreDTO].self, from: sentBody)
                #expect(decoded.first?.id == 9)
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

        /// HTTP キャッシュ追随修正（G4d 見落とし fix）: version 付きで開いた本のページ URL は
        /// `?v=<versionValue>` を持ち、その値は RemoteBookContent.versionValue（＝アプリ層
        /// キャッシュキーが使う正規化済み版）と完全一致すること。ここがずれると、URL 版と
        /// キャッシュキー版が食い違う「半分だけ版管理された」状態になり、本 bug と同種の
        /// 不整合が再発する。version 付き URL は immutable が健全なので既定ポリシーのままでよい。
        @Test func imageDataURLCarriesVersionMatchingVersionValue() async throws {
            let bytes = Data([0xFF, 0xD8, 0x01, 0x02])
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: bytes)
            let content = RemoteBookContent(client: client(), serverID: UUID(), libraryUUID: "u", bookID: 9,
                                            libraryToken: nil, maxWidth: 1600, version: "\"etag-abc\"", cache: nil)
            _ = try await content.imageData(at: 3)
            let url = StubURLProtocol.lastRequest?.url
            let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
            let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            // versionValue は normalizeVersion 済み（クォート剥がし後）— URL の v= もそれと同じでなければならない。
            #expect(items["v"] == content.versionValue)
            #expect(content.versionValue == "etag-abc")
            #expect(StubURLProtocol.lastRequest?.cachePolicy == .useProtocolCachePolicy)
        }

        /// version が無い（manifest 取得失敗等のフォールバック）ときは、今日の挙動どおり URL に
        /// `v=` を付けない。かつ、版不明な versionless URL の immutable エントリを信用しないよう
        /// cover と同じ方針で URLCache をバイパスする（.reloadIgnoringLocalCacheData）。
        @Test func imageDataNoVersionOmitsVAndBypassesURLCache() async throws {
            let bytes = Data([0xFF, 0xD8, 0x01, 0x02])
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: bytes)
            let content = RemoteBookContent(client: client(), serverID: UUID(), libraryUUID: "u", bookID: 9,
                                            libraryToken: nil, maxWidth: 1600, cache: nil)   // version 省略 → nil
            #expect(content.versionValue == nil)
            _ = try await content.imageData(at: 3)
            let url = StubURLProtocol.lastRequest?.url
            #expect(url?.query?.contains("v=") != true)
            #expect(StubURLProtocol.lastRequest?.cachePolicy == .reloadIgnoringLocalCacheData)
        }

        /// G4d 層2 (native) 配線の実地確認: imageData(at:) が実際に version 付きの
        /// RemotePageCache.Key を組み立てていることを、HTTP スタブの実リクエスト回数で証明する。
        /// relink 後に manifest.etag（version）が変わった想定＝別 RemoteBookContent 生成でも
        /// 同一 page は必ず再取得され（stale page を握り続けない）、version が変わらない再オープンは
        /// キャッシュヒットして再取得しない（帯域節約が壊れていない）ことを確認する。
        @Test func versionedContentRefetchesOnVersionChangeAndHitsWhenUnchanged() async throws {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("rbc-ver-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let cache = RemotePageCache(baseDirectory: tempDir, limitBytes: 0, maxAgeSeconds: 0)
            let sid = UUID()
            StubURLProtocol.requestCount = 0

            StubURLProtocol.stub = .init(status: 200, headers: [:], body: Data([1, 1, 1]))
            let v1 = RemoteBookContent(client: client(), serverID: sid, libraryUUID: "u", bookID: 42,
                                       libraryToken: nil, maxWidth: 1600, version: "etag-v1", cache: cache)
            _ = try await v1.imageData(at: 0)
            #expect(StubURLProtocol.requestCount == 1)

            // 同一 version で開き直す（例: 巻を閉じてまた開く）→ ヒットして実リクエストは増えない。
            let v1Again = RemoteBookContent(client: client(), serverID: sid, libraryUUID: "u", bookID: 42,
                                            libraryToken: nil, maxWidth: 1600, version: "etag-v1", cache: cache)
            _ = try await v1Again.imageData(at: 0)
            #expect(StubURLProtocol.requestCount == 1)   // ヒット・再取得なし

            // relink でサーバの本体が差し替わり etag が変わった想定 → 同じ page でも必ず再取得される。
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: Data([2, 2, 2]))
            let v2 = RemoteBookContent(client: client(), serverID: sid, libraryUUID: "u", bookID: 42,
                                       libraryToken: nil, maxWidth: 1600, version: "etag-v2", cache: cache)
            let data2 = try await v2.imageData(at: 0)
            #expect(StubURLProtocol.requestCount == 2)   // ミス・再取得
            #expect(data2 == Data([2, 2, 2]))
        }

        /// review follow-up Finding 1: サーバが `Cache-Control: no-store` で返した応答
        /// （リクエストの `?v=` が現在版と食い違う＝relink 直後にまだ旧版の URL が使われている状態）
        /// は、バイト自体は呼び出し元へ返す（表示に使ってよい）が `RemotePageCache` へ永続化して
        /// はならない。
        ///
        /// 失敗シナリオ（このテストが再現する不具合そのもの）: リーダーが version A で開く →
        /// 外部で relink されて版が B に切り替わる → 旧版キー(vA)での再取得が
        /// `?v=A` を伴って飛び、サーバは現在の正しいバイト（B）を 200 + no-store で返す →
        /// ここで store してしまうと、B のバイトが RemotePageCache の vA キーの下に固定され、
        /// 後で A へ relink し戻ったとき vA キーが即ヒットして B のページが（TTL まで）
        /// 表示され続ける。
        ///
        /// 検証方法: 同一 version・同一 page に対して1回目は no-store 応答（body=A）、
        /// 2回目は別の body（B）を stub し、2回目も実リクエストが飛ぶこと（＝1回目が
        /// キャッシュに保存されていないこと）を実リクエスト回数で確認する。もし保存していれば
        /// 2回目が HIT して実リクエストが増えず、かつ 2回目の戻り値が古い body(A) のままになる
        /// （このテストは両方を見る）。
        @Test func imageDataDoesNotPersistNoStoreResponseToPageCache() async throws {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("rbc-nostore-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let cache = RemotePageCache(baseDirectory: tempDir, limitBytes: 0, maxAgeSeconds: 0)
            let sid = UUID()
            StubURLProtocol.requestCount = 0

            // 1回目: サーバが no-store で応答（?v= が現在版と食い違うケースを模す）。
            StubURLProtocol.stub = .init(status: 200, headers: ["Cache-Control": "no-store"], body: Data([0xA]))
            let content = RemoteBookContent(client: client(), serverID: sid, libraryUUID: "u", bookID: 42,
                                            libraryToken: nil, maxWidth: 1600, version: "etag-v1", cache: cache)
            let data1 = try await content.imageData(at: 0)
            #expect(data1 == Data([0xA]), "no-store でも今の正しいバイトはそのまま返す")
            #expect(StubURLProtocol.requestCount == 1)

            // 2回目: 同一 version・同一 page・別 body を stub。
            // store していなければ必ずミス→再取得され、2回目の戻り値は新 body(B) になる。
            StubURLProtocol.stub = .init(status: 200, headers: [:], body: Data([0xB]))
            let contentAgain = RemoteBookContent(client: client(), serverID: sid, libraryUUID: "u", bookID: 42,
                                                 libraryToken: nil, maxWidth: 1600, version: "etag-v1", cache: cache)
            let data2 = try await contentAgain.imageData(at: 0)
            #expect(StubURLProtocol.requestCount == 2,
                     "no-store 応答が RemotePageCache に保存されている — 誤った版キーの下へバイトが固定される（relink 巻き戻し時に stale 表示が再発する）")
            #expect(data2 == Data([0xB]),
                     "1回目の no-store 応答が誤ってキャッシュから返っている（stale バイト）")
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

        /// #12: 進捗つきダウンロードは通常サイズの本文なら従来どおり全バイトを取得できる（回帰なし）。
        @Test func bookFileWithProgressReturnsNormalSizedBytes() async throws {
            let bytes = Data(repeating: 0xAB, count: 4096)
            StubURLProtocol.stub = .init(status: 200, headers: ["Content-Length": "4096"], body: bytes)
            let url = try await makeClient().bookFile(libraryUUID: "u", bookID: 9, libraryToken: nil,
                                                      onProgress: nil, shouldCancel: nil)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try Data(contentsOf: url) == bytes)
        }

        /// G23 (M2): 64KiB のバッファ境界をまたぐサイズでも欠落なく書き出す。
        @Test func bookFileWritesAcrossBufferBoundary() async throws {
            let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
            StubURLProtocol.stub = .init(status: 200, headers: ["Content-Length": "200000"], body: bytes)
            let url = try await makeClient().bookFile(libraryUUID: "u", bookID: 9, libraryToken: nil,
                                                      onProgress: nil, shouldCancel: nil)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try Data(contentsOf: url) == bytes)
        }

        /// G23 (M2): キャンセルされた場合、一時ファイルを残さない。
        @Test func cancelledDownloadLeavesNoTemporaryFile() async throws {
            let before = try temporaryDownloadFileCount()
            StubURLProtocol.stub = .init(status: 200, headers: ["Content-Length": "200000"],
                                         body: Data(repeating: 0xCD, count: 200_000))
            await #expect(throws: CancellationError.self) {
                _ = try await makeClient().bookFile(libraryUUID: "u", bookID: 9, libraryToken: nil,
                                                    onProgress: nil, shouldCancel: { true })
            }
            #expect(try temporaryDownloadFileCount() == before)
        }

        /// エラー応答でも一時ファイルを残さない。
        @Test func failedDownloadLeavesNoTemporaryFile() async throws {
            let before = try temporaryDownloadFileCount()
            StubURLProtocol.stub = .init(status: 404, headers: [:], body: Data())
            await #expect(throws: RemoteClientError.self) {
                _ = try await makeClient().bookFile(libraryUUID: "u", bookID: 9, libraryToken: nil,
                                                    onProgress: nil, shouldCancel: nil)
            }
            #expect(try temporaryDownloadFileCount() == before)
        }

        /// `stacknest-dl-*` の残骸数を数える（テスト間で他の一時ファイルに影響されないよう接頭辞で絞る）。
        private func temporaryDownloadFileCount() throws -> Int {
            let dir = FileManager.default.temporaryDirectory
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            return names.filter { $0.hasPrefix("stacknest-dl-") }.count
        }
    }
}

/// #12: クライアント側 DoS 対策として追加したガード関数・定数の直接検証。
/// 実際に GiB 単位のデータを流すのは非現実的なので、境界値の純粋な計算のみをテストする。
@Suite("RemoteLibraryClient download guards (#12)")
struct RemoteLibraryClientDownloadGuardTests {
    // G23 (M2): clampedReserveCapacity 系のテストは削除した。ストリーミング化で
    // `Data.reserveCapacity` 自体を使わなくなり、対象の関数ごと不要になったため。

    @Test func exceedsMaxDownloadBytesFalseAtAndBelowLimit() {
        #expect(RemoteLibraryClient.exceedsMaxDownloadBytes(received: 0) == false)
        #expect(RemoteLibraryClient.exceedsMaxDownloadBytes(received: RemoteLibraryClient.maxDownloadBytes) == false)
    }
    @Test func exceedsMaxDownloadBytesTrueJustAboveLimit() {
        #expect(RemoteLibraryClient.exceedsMaxDownloadBytes(received: RemoteLibraryClient.maxDownloadBytes + 1) == true)
    }

    // MARK: - G23 (M1): 汎用取得経路の受信上限

    /// 宣言 Content-Length が上限超なら、本文を扱う前に拒否する。
    @Test func generalLimitRejectsOversizedDeclaredLength() {
        let over = Int64(RemoteLibraryClient.maxGeneralResponseBytes) + 1
        #expect(RemoteLibraryClient.exceedsGeneralLimit(declaredLength: over, receivedCount: 0) == true)
    }

    /// Content-Length を詐称（または省略）されても、実受信量で再判定して拒否する。
    @Test func generalLimitRejectsOversizedReceivedCount() {
        let over = RemoteLibraryClient.maxGeneralResponseBytes + 1
        #expect(RemoteLibraryClient.exceedsGeneralLimit(declaredLength: -1, receivedCount: over) == true)
    }

    /// 通常サイズ（JSON・表紙・ページ）は影響を受けない。
    @Test func generalLimitAcceptsNormalSizes() {
        #expect(RemoteLibraryClient.exceedsGeneralLimit(declaredLength: 1024, receivedCount: 1024) == false)
        #expect(RemoteLibraryClient.exceedsGeneralLimit(declaredLength: -1, receivedCount: 4096) == false)
        #expect(RemoteLibraryClient.exceedsGeneralLimit(
            declaredLength: Int64(RemoteLibraryClient.maxGeneralResponseBytes),
            receivedCount: RemoteLibraryClient.maxGeneralResponseBytes) == false)   // 境界（上限ちょうど）は許可
    }

    /// 本ファイルの上限（maxDownloadBytes）とは別枠で、汎用経路の方が小さい。
    @Test func generalLimitIsSmallerThanBookFileLimit() {
        #expect(Int64(RemoteLibraryClient.maxGeneralResponseBytes) < RemoteLibraryClient.maxDownloadBytes)
    }

    // G23 Codex High #3: 「宣言 Content-Length の詐称を弾く」統合テストは書けなかった。
    // `StubURLProtocol` が `Content-Length` ヘッダを立てても、`URLProtocol` が `didLoad` で
    // 渡した実データ長が `expectedContentLength` になるため、**詐称そのものを再現できない**。
    // 判定ロジックは `generalLimitRejectsOversizedDeclaredLength` ほかの単体テストで担保し、
    // 逐次受信で実際に打ち切る経路は下の境界テストと実機 smoke で確認する。


    /// #13: リダイレクト拒否デリゲートは 3xx に一切従わない（completionHandler(nil)）。
    @Test func noRedirectDelegateDeniesRedirect() async {
        let delegate = RemoteLibraryClient.NoRedirectSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "http://h:8080/api/v1/libraries")!)
        let redirect = HTTPURLResponse(url: URL(string: "http://evil.example/steal")!,
                                       statusCode: 302, httpVersion: nil, headerFields: nil)!
        let hop = URLRequest(url: URL(string: "http://evil.example/steal")!)
        let captured: URLRequest? = await withCheckedContinuation { cont in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                                newRequest: hop) { cont.resume(returning: $0) }
        }
        #expect(captured == nil)   // リダイレクトに従わない＝資格情報が別ホストへ送られない
        task.cancel(); session.invalidateAndCancel()
    }
}
