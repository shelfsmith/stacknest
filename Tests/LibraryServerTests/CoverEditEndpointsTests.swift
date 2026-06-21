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

    /// JSON 文字列値をエスケープして埋め込む（cropJSON は JSON 文字列）。
    private func jsonString(_ s: String) -> String {
        let data = try! JSONEncoder().encode(s)
        return String(decoding: data, as: UTF8.self)
    }
}
