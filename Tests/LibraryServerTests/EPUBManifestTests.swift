// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import AppCore
import LibraryServerAPI
@testable import LibraryServer

@Suite("G48-3: manifest の EPUB フォールバック")
struct EPUBManifestTests {
    @Test("純粋判定: .epub × unsupported(.text) だけ true")
    func fallbackDecision() {
        #expect(EPUBManifestFallback.isTextEPUB(path: "/x/a.epub", error: BookContentError.unsupported(.text)))
        #expect(EPUBManifestFallback.isTextEPUB(path: "/x/A.EPUB", error: BookContentError.unsupported(.text)))
        #expect(!EPUBManifestFallback.isTextEPUB(path: "/x/a.zip", error: BookContentError.unsupported(.text)))
        #expect(!EPUBManifestFallback.isTextEPUB(path: "/x/a.epub", error: BookContentError.pageOutOfRange(3)))
        #expect(!EPUBManifestFallback.isTextEPUB(path: nil, error: BookContentError.unsupported(.text)))
    }

    @Test("ManifestDTO は epubLocator が nil ならキーを出さない")
    func manifestOmitsNilLocator() throws {
        let m = ManifestDTO(pageCount: 0, direction: "rtl", format: "epub", etag: "\"e\"")
        let json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        #expect(!json.contains("epubLocator"))
        let m2 = ManifestDTO(pageCount: 0, direction: "rtl", format: "epub", etag: "\"e\"",
                             epubLocator: EPUBLocatorDTO(spine: 3, progress: 0.5, cfi: nil, engine: "washi"))
        let json2 = String(decoding: try JSONEncoder().encode(m2), as: UTF8.self)
        #expect(json2.contains("\"epubLocator\""))
        let back = try JSONDecoder().decode(ManifestDTO.self, from: Data(json2.utf8))
        #expect(back.epubLocator?.spine == 3)
    }

    /// 統合: .epub の行（reader 未登録＝テキスト扱い）で manifest が 500 にならず epub 形式で返る。
    /// `EPUBAdapter.reader` は触らない（global は AppCoreTests の serialized suite だけが触る）。
    /// 並走中の AppCoreTests が一時的に画像本 handle を返す reader を登録している可能性が
    /// あるので、format が "epub" のときだけ pageCount==0 と epubLocator を断言する。
    @Test("統合: .epub の manifest は 500 にならない")
    func manifestForTextEPUB() async throws {
        let fixture = try TestLibraryFixture(name: "E", bookCount: 0)
        let bookID = try fixture.addDummyFileBook(named: "novel.epub")   // Step 3 で fixture に追加
        try fixture.db.updateEPUBLocator(bookID: bookID, json: #"{"spine":2,"progress":0.25,"engine":"washi"}"#)
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(config: .init(port: 0, token: "tk"),
                                    dataSource: StaticLibraryDataSource(libraries: [lib])).buildApplication()
        try await app.test(.router) { client in
            let res = try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/manifest", method: .get,
                headers: [.authorization: "Bearer tk"])
            #expect(res.status == .ok)
            let m = try JSONDecoder().decode(ManifestDTO.self, from: res.body)
            if m.format == "epub" {
                #expect(m.pageCount == 0)
                #expect(m.epubLocator?.spine == 2)
                #expect(m.epubLocator?.engine == "washi")
            }
        }
    }

    @Test("/file は .epub に application/epub+zip を付ける")
    func fileContentTypeForEPUB() async throws {
        let fixture = try TestLibraryFixture(name: "F", bookCount: 0)
        let bookID = try fixture.addDummyFileBook(named: "novel.epub")
        let lib = fixture.servedLibrary()
        let app = LibraryServerCore(config: .init(port: 0, token: "tk"),
                                    dataSource: StaticLibraryDataSource(libraries: [lib])).buildApplication()
        try await app.test(.router) { client in
            let res = try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/file", method: .get,
                headers: [.authorization: "Bearer tk"])
            #expect(res.status == .ok)
            #expect(res.headers[.contentType] == "application/epub+zip")
        }
    }

    @Test("WebP を sniff する")
    func sniffWebP() {
        var d = Data("RIFF".utf8); d.append(contentsOf: [0x10, 0, 0, 0]); d.append(contentsOf: Array("WEBPVP8 ".utf8))
        #expect(sniffImageContentType(d) == "image/webp")
        #expect(sniffImageContentType(Data("RIFFxxxxWAVE".utf8)) == "application/octet-stream")
    }
}
