// SPDX-License-Identifier: MIT
import Testing
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// manifest の `bookIdentity`（`ViewerBookIdentity`）: 外部ビューアが本ごとの記録の鍵に使う本の同一性。
@Suite("manifest の本の同一性")
struct ViewerBookIdentityTests {
    /// StackNestViewerKit が受け付ける形（ASCII の英数字と `-._~:`・1〜128 文字）。部品の 0.2.0 はこの項目を
    /// 読まないので、形は文書の約束を写して確かめる。
    static func hasKitShape(_ value: String) -> Bool {
        (1...128).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || "-._~:".unicodeScalars.contains($0)
        }
    }

    private func manifest(_ app: some ApplicationProtocol, uuid: String, bookID: Int) async throws -> ManifestDTO {
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries/\(uuid)/books/\(bookID)/manifest", method: .get,
                                     headers: [.authorization: "Bearer R"]) { response in
                #expect(response.status == .ok)
                return try JSONDecoder().decode(ManifestDTO.self, from: Data(buffer: response.body))
            }
        }
    }

    private func app(_ lib: ServedLibrary) -> some ApplicationProtocol {
        LibraryServerCore(config: .init(port: 0, token: "R"),
                          dataSource: StaticLibraryDataSource(libraries: [lib])).buildApplication()
    }

    @Test("値は書庫・本の番号・取り込み日時（秒）から決まり、形は部品の約束に収まる")
    func valueIsDeterministicAndFitsTheKitShape() {
        let added = Date(timeIntervalSince1970: 1_800_000_000.25)
        let value = ViewerBookIdentity.value(libraryUUID: "AAAA-1", bookID: 7, dateAdded: added)
        #expect(value.hasPrefix(ViewerBookIdentity.prefix))
        #expect(value.count == 47)
        #expect(Self.hasKitShape(value))
        #expect(value == ViewerBookIdentity.value(libraryUUID: "aaaa-1", bookID: 7,
                                                  dateAdded: Date(timeIntervalSince1970: 1_800_000_000.9)),
                "書庫の UUID の大文字小文字と、秒未満の違いでは変わらない")
        #expect(value != ViewerBookIdentity.value(libraryUUID: "AAAA-1", bookID: 8, dateAdded: added))
        #expect(value != ViewerBookIdentity.value(libraryUUID: "AAAA-2", bookID: 7, dateAdded: added))
        #expect(value != ViewerBookIdentity.value(libraryUUID: "AAAA-1", bookID: 7,
                                                  dateAdded: Date(timeIntervalSince1970: 1_800_000_001)),
                "番号が使い回されても（取り込み日時が違えば）別の値")
    }

    @Test("manifest に載り、改題・付け直し（パスの変更）の後も同じ。別の本・別の書庫とは違う")
    func manifestCarriesAStableIdentity() async throws {
        let fixture = try TestLibraryFixture(name: "BI", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let (otherID, _) = try fixture.addFolderBook(imageCount: 2)
        let lib = fixture.servedLibrary()
        let app = app(lib)
        let first = try await manifest(app, uuid: lib.uuid, bookID: bookID)
        let identity = try #require(first.bookIdentity)
        #expect(Self.hasKitShape(identity))
        let row = try #require(try lib.db.fetchBook(id: bookID))
        #expect(identity == ViewerBookIdentity.value(libraryUUID: lib.uuid, bookID: bookID, dateAdded: row.dateAdded))

        var patch = BookPatch()
        patch.title = "Renamed"
        try lib.db.updateBook(id: bookID, patch: patch)
        let moved = try fixture.copyFixtureZip(named: "pdf-only", as: "moved.zip")
        try lib.db.updateBookPath(id: bookID, newPath: moved.path)
        let after = try await manifest(app, uuid: lib.uuid, bookID: bookID)
        #expect(after.bookIdentity == identity)
        #expect(after.etag != first.etag, "中身の版（etag）はパスで変わるが、同一性は変わらない")

        let other = try await manifest(app, uuid: lib.uuid, bookID: otherID)
        #expect(other.bookIdentity != nil)
        #expect(other.bookIdentity != identity)

        let fixture2 = try TestLibraryFixture(name: "BI2", bookCount: 0)
        defer { fixture2.cleanup() }
        let bookID2 = try fixture2.addRealBook(zipFixtureNamed: "pdf-only")
        let lib2 = fixture2.servedLibrary()
        let elsewhere = try await manifest(self.app(lib2), uuid: lib2.uuid, bookID: bookID2)
        #expect(elsewhere.bookIdentity != identity)
    }

    @Test("テキスト EPUB の manifest（format epub）にも載る")
    func textEPUBManifestCarriesIdentity() async throws {
        let fixture = try TestLibraryFixture(name: "BI3", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addDummyFileBook(named: "text.epub")
        let lib = fixture.servedLibrary()
        let dto = try await manifest(app(lib), uuid: lib.uuid, bookID: bookID)
        #expect(dto.format == "epub")
        #expect(dto.bookIdentity.map(Self.hasKitShape) == true)
    }

    @Test("同一性の無い manifest（古いサーバ）はキーごと省き、今の DTO で読める")
    func identityIsOmittedWhenAbsent() throws {
        let data = try JSONEncoder().encode(ManifestDTO(pageCount: 1, direction: "rtl", format: "archive", etag: "e"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["bookIdentity"] == nil)
        let old = Data(#"{"pageCount":1,"direction":"rtl","format":"archive","etag":"e"}"#.utf8)
        #expect(try JSONDecoder().decode(ManifestDTO.self, from: old).bookIdentity == nil)
    }
}
