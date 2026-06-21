// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
@testable import LibraryServer
@testable import LibraryStore

@Suite("cover-candidates / PUT cover")
struct CoverEditEndpointsTests {
    private func makeApp(_ lib: ServedLibrary, editToken: String? = "W") -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: editToken),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
    }

    /// cover-candidates は 200（pdf-only fixture では画像エントリ無し＝空配列でも 200）。
    @Test func coverCandidatesReturns200() async throws {
        let fixture = try TestLibraryFixture(name: "Cover1", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover-candidates",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                _ = try JSONDecoder().decode(CoverCandidatesDTO.self, from: Data(buffer: response.body))
            }
        }
    }

    /// PUT cover の crop 更新（W）は DB に反映され、thumbnail 再生成不要（extractor 非依存）。
    @Test func putCoverCropUpdatesDB() async throws {
        let fixture = try TestLibraryFixture(name: "Cover2", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        let cropJSON = BookRow.encodeCoverCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(string: #"{"setCoverImageName":false,"setCoverCropRect":true,"coverCropRect":\#(jsonString(cropJSON))}"#)
            ) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(try fixture.db.fetchBook(id: bookID)?.coverCropRect != nil)
    }

    /// PUT cover は RW 専用：R は 403。
    @Test func putCoverRequiresWrite() async throws {
        let fixture = try TestLibraryFixture(name: "Cover3", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "pdf-only")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover",
                method: .put,
                headers: [.authorization: "Bearer R", .contentType: "application/json"],
                body: .init(string: #"{"setCoverImageName":false,"setCoverCropRect":true,"coverCropRect":"{}"}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// cover-candidates は実アーカイブの画像エントリを natural-sort 順で返す（current は未設定なら nil）。
    @Test func coverCandidatesReturnsRealEntries() async throws {
        let fixture = try TestLibraryFixture(name: "Cover4", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "three_pages")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover-candidates",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(CoverCandidatesDTO.self, from: Data(buffer: response.body))
                #expect(dto.entries == ["p1.png", "p2.png", "p10.png"])
                #expect(dto.current == nil)
            }
        }
    }

    /// entry-image?name=<entry> は 200 で当該ページの画像バイト（PNG）を返す。
    @Test func entryImageReturnsBytes() async throws {
        let fixture = try TestLibraryFixture(name: "Cover5", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "three_pages")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/entry-image?name=p2.png",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .ok)
                #expect(Data(buffer: response.body).count > 0)
            }
        }
    }

    /// entry-image で存在しないエントリ名は 404。
    @Test func entryImageMissingNameRequired() async throws {
        let fixture = try TestLibraryFixture(name: "Cover6", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "three_pages")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/entry-image",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    /// PUT cover の coverImageName 更新（W）は DB に反映され、Thumbnails/<id>/thumbnail.jpg を再生成する。
    @Test func putCoverWithImageNameRegeneratesThumbnail() async throws {
        let fixture = try TestLibraryFixture(name: "Cover7", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "three_pages")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        let thumb = lib.bundleURL
            .appendingPathComponent("Thumbnails/\(bookID)")
            .appendingPathComponent("thumbnail.jpg")
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(string: #"{"setCoverImageName":true,"coverImageName":"p10.png","setCoverCropRect":false}"#)
            ) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(try fixture.db.fetchBook(id: bookID)?.coverImageName == "p10.png")
        #expect(FileManager.default.fileExists(atPath: thumb.path))
    }

    /// JSON 文字列値をエスケープして埋め込む（cropJSON は JSON 文字列）。
    private func jsonString(_ s: String) -> String {
        let data = try! JSONEncoder().encode(s)
        return String(decoding: data, as: UTF8.self)
    }
}
