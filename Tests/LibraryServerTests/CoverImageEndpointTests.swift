// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppKit
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import AppCore
import LibraryStore
@testable import LibraryServer

/// G4b: サーバ `PUT /libraries/:lib/books/:id/cover-image`。
/// 画像バイトを thumbnail.jpg として保存し、coverImageName="@external" ＋任意 crop を設定する。
@Suite("PUT cover-image endpoint")
struct CoverImageEndpointTests {

    private func makeApp(_ lib: ServedLibrary, editToken: String? = "W") -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: editToken),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
    }

    /// 32x32 の赤 JPEG を生成する。
    private func redJPEG() -> Data {
        let img = NSImage(size: NSSize(width: 32, height: 32))
        img.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return rep.representation(using: .jpeg, properties: [:])!
    }

    /// クエリ値を安全に percent-encode（JSON をそのまま query に載せるため）。
    private func encodeQuery(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    /// RW で赤 JPEG を PUT → 200・coverImageName=="@external"・thumbnail 生成・GET cover 200・crop 反映。
    @Test func putCoverImageStoresExternalCover() async throws {
        let fixture = try TestLibraryFixture(name: "CoverImg1", bookCount: 1)
        defer { fixture.cleanup() }
        let bookID = 1
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        let thumb = lib.bundleURL
            .appendingPathComponent("Thumbnails/\(bookID)")
            .appendingPathComponent("thumbnail.jpg")
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
        let cropJSON = BookRow.encodeCoverCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover-image?crop=\(encodeQuery(cropJSON))",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "image/jpeg"],
                body: .init(bytes: Array(redJPEG()))
            ) { resp in
                #expect(resp.status == .ok)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let dto = try decoder.decode(BookDetailDTO.self, from: Data(buffer: resp.body))
                #expect(dto.coverImageName == "@external")
            }
            // GET cover は 200 で差し替え済み画像を返す。
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover",
                method: .get, headers: [.authorization: "Bearer R"]
            ) { resp in
                #expect(resp.status == .ok)
                #expect(Data(buffer: resp.body).count > 0)
            }
        }
        // ディスクに thumbnail.jpg が生成されている。
        #expect(FileManager.default.fileExists(atPath: thumb.path))
        // crop も DB に反映されている。
        #expect(try fixture.db.fetchBook(id: bookID)?.coverCropRect != nil)
        // coverImageName が @external として永続化されている。
        #expect(try fixture.db.fetchBook(id: bookID)?.coverImageName == "@external")
    }

    /// R（読取）トークンでは 403。
    @Test func putCoverImageRequiresWrite() async throws {
        let fixture = try TestLibraryFixture(name: "CoverImg2", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/cover-image",
                method: .put,
                headers: [.authorization: "Bearer R", .contentType: "image/jpeg"],
                body: .init(bytes: Array(redJPEG()))
            ) { resp in
                #expect(resp.status == .forbidden)
            }
        }
    }

    /// 空ボディは 400。
    @Test func putCoverImageNonImageIsBadRequest() async throws {
        let fixture = try TestLibraryFixture(name: "CoverImgNI", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/cover-image",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "image/jpeg"],
                body: .init(bytes: Array("this is not an image".utf8))
            ) { resp in
                #expect(resp.status == .badRequest)   // CGImageSource デコード不可 → 400
            }
        }
    }

    @Test func putCoverImageEmptyBodyIsBadRequest() async throws {
        let fixture = try TestLibraryFixture(name: "CoverImg3", bookCount: 1)
        defer { fixture.cleanup() }
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/1/cover-image",
                method: .put,
                headers: [.authorization: "Bearer W", .contentType: "image/jpeg"],
                body: .init(bytes: [])
            ) { resp in
                #expect(resp.status == .badRequest)
            }
        }
    }
}
