// SPDX-License-Identifier: MIT
import Testing
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import StackroomFormat
import AppCore
@testable import LibraryServer

/// manifest の `pageNames`（`?pageNames=1`）: 外部ビューアに、`pages/{n}` の番号の順のページの名前を返す。
@Suite("manifest のページの名前")
struct ManifestPageNamesTests {
    /// 書庫の中にフォルダのある zip を作る（`/usr/bin/zip` を相対パスで。ArchiveAdapterTests の zipFiles と同じ道具）。
    static func makeZip(entries: [String], in directory: URL, named name: String) throws -> URL {
        let source = directory.appendingPathComponent("src-\(UUID().uuidString)")
        for entry in entries {
            let file = source.appendingPathComponent(entry)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("png:\(entry)".utf8).write(to: file)
        }
        let zip = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-q", "-r", zip.path] + entries
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        try FileManager.default.removeItem(at: source)
        return zip
    }

    private func app(_ lib: ServedLibrary) -> some ApplicationProtocol {
        LibraryServerCore(config: .init(port: 0, token: "R"),
                          dataSource: StaticLibraryDataSource(libraries: [lib])).buildApplication()
    }

    private func manifest(_ app: some ApplicationProtocol, _ path: String) async throws -> (ManifestDTO, [String: Any]) {
        try await app.test(.router) { client in
            try await client.execute(uri: path, method: .get, headers: [.authorization: "Bearer R"]) { response in
                #expect(response.status == .ok)
                let data = Data(buffer: response.body)
                let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                return (try JSONDecoder().decode(ManifestDTO.self, from: data), object)
            }
        }
    }

    @Test("書庫の本: ?pageNames=1 で書庫の中のパスを pages/{n} の順に返す。問い合わせが無い・ほかの値ならキーごと省く")
    func archiveBookNamesFollowPageOrder() async throws {
        let fixture = try TestLibraryFixture(name: "PN", bookCount: 0)
        defer { fixture.cleanup() }
        let zip = try Self.makeZip(entries: ["ch2/001.png", "ch1/010.png", "ch1/002.png", "cover.jpg"],
                                   in: fixture.bundleURL, named: "nested.zip")
        let bookID = try fixture.db.insertBookReturningID(BookRecord(id: 0, title: "Nested", path: zip.path, dateAdded: Date()))
        let lib = fixture.servedLibrary()
        let app = app(lib)
        let base = "/api/v1/libraries/\(lib.uuid)/books/\(bookID)"

        let (named, _) = try await manifest(app, "\(base)/manifest?pageNames=1")
        #expect(named.pageNames == ["ch1/002.png", "ch1/010.png", "ch2/001.png", "cover.jpg"])
        #expect(named.pageNames?.count == named.pageCount)
        // 名前と pages/{n} の対応: 本の中身の一覧と同じ順（BookContent.imageData の番号）。
        let content = try BookContentFactory.make(path: zip.path, userExtensions: [:])
        for (n, name) in try #require(named.pageNames).enumerated() {
            #expect(String(decoding: try await content.imageData(at: n), as: UTF8.self) == "png:\(name)")
        }
        for path in ["\(base)/manifest", "\(base)/manifest?pageNames=0", "\(base)/manifest?pageNames=true"] {
            let (plain, object) = try await manifest(app, path)
            #expect(plain.pageNames == nil, "\(path)")
            #expect(object["pageNames"] == nil, "\(path)")
            #expect(plain.pageCount == 4)
        }
    }

    @Test("フォルダの本・画像 1 枚の本は名前を返し、PDF の本（名前の無い本）はキーごと省く")
    func folderSingleImageAndPDFBooks() async throws {
        let fixture = try TestLibraryFixture(name: "PN2", bookCount: 0)
        defer { fixture.cleanup() }
        let (folderID, _) = try fixture.addFolderBook(imageCount: 3)
        let imageID = try fixture.addImageBook()
        let pdfID = try fixture.addPDFBook()
        let zipPDFID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = app(lib)
        func path(_ id: Int) -> String { "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest?pageNames=1" }
        #expect(try await manifest(app, path(folderID)).0.pageNames == ["page0.jpg", "page1.jpg", "page2.jpg"])
        let image = try await manifest(app, path(imageID)).0
        #expect(image.pageNames?.count == 1)
        #expect(try await manifest(app, path(pdfID)).1["pageNames"] == nil)
        let zipPDF = try await manifest(app, path(zipPDFID))
        #expect(zipPDF.0.pageCount == 5)
        #expect(zipPDF.1["pageNames"] == nil, "画像が無く中の PDF で読む書庫は名前を付けない")
    }

    @Test("本専用の鍵でも ?pageNames=1 の manifest は通る（道の許可は問い合わせを見ない）")
    func viewerTokenMayAskForNames() async throws {
        let fixture = try TestLibraryFixture(name: "PN3", bookCount: 0)
        defer { fixture.cleanup() }
        let (id, _) = try fixture.addFolderBook(imageCount: 2)
        let lib = fixture.servedLibrary()
        let suite = "pn3-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ViewerTokenStore(defaults: defaults)
        let stamp = ViewerTokenRecord.bookStamp(dateAdded: try #require(try lib.db.fetchBook(id: id)).dateAdded)
        let issued = store.issue(libraryUUID: lib.uuid, bookID: id, bookStamp: stamp, issuer: .sharedServer,
                                 lockCredential: nil)
        let app = LibraryServerCore(
            config: .init(port: 0, token: "tk", viewerTokens: store, viewerTokenIssuer: .sharedServer),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)/manifest?pageNames=1", method: .get,
                                     headers: [.authorization: "Bearer \(issued.token)"]) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(ManifestDTO.self, from: Data(buffer: response.body))
                #expect(dto.pageNames == ["page0.jpg", "page1.jpg"])
            }
        }
    }

    @Test("中継は manifest の pageNames=1 だけをリモートへ渡し、ほかの道の pageNames とほかのクエリは落とす")
    func relayPassesPageNamesOnlyForManifest() throws {
        let target = ViewerRelayTarget(serverID: UUID(), serverBase: URL(string: "http://100.64.0.5:51234/")!,
                                       libraryUUID: "LIB-R", bookID: 42, remoteToken: "REMOTE")
        func outgoing(_ remotePath: String, _ uri: String) throws -> String {
            let request = Request(head: HTTPRequest(method: .get, scheme: "http", authority: "127.0.0.1", path: uri),
                                  body: .init(buffer: ByteBuffer()))
            let made = try #require(ViewerRelayForwarder.makeRemoteRequest(target, remotePath: remotePath,
                                                                           request: request, body: nil))
            return try #require(made.url?.absoluteString)
        }
        let book = "http://100.64.0.5:51234/api/v1/libraries/LIB-R/books/42"
        #expect(try outgoing("manifest", "/api/v1/relay/R/manifest?pageNames=1&other=x") == "\(book)/manifest?pageNames=1")
        #expect(try outgoing("manifest", "/api/v1/relay/R/manifest?pageNames=2") == "\(book)/manifest")
        #expect(try outgoing("manifest", "/api/v1/relay/R/manifest") == "\(book)/manifest")
        #expect(try outgoing("pages/3", "/api/v1/relay/R/pages/3?pageNames=1&maxw=800") == "\(book)/pages/3?maxw=800")
        #expect(try outgoing("cover", "/api/v1/relay/R/cover?pageNames=1") == "\(book)/cover")
    }

    @Test("名前の無い manifest（古いサーバ）は今の DTO で読める")
    func oldManifestsDecode() throws {
        let old = Data(#"{"pageCount":1,"direction":"rtl","format":"archive","etag":"e"}"#.utf8)
        #expect(try JSONDecoder().decode(ManifestDTO.self, from: old).pageNames == nil)
    }
}
