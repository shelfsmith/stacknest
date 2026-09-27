// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import AppCore
import LibraryServerAPI
import LibraryStore
@testable import LibraryServer

/// G55 Task 14 (U6): `HTTPError(..., message:)` が `LanguageMiddleware` の言語で組まれることの
/// エンドポイント越しの固定（Review Focus 5 の別角度: サーバのエラー文そのものが英語になる）。
@Suite("HTTPError message follows Accept-Language (G55 U6)")
struct HTTPErrorMessageLanguageTests {
    private func makeApp(_ lib: ServedLibrary) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
    }

    /// cover/regenerate は真に表紙を作れない形式で 400 を返す（`CoverRegenerateEndpointTests` と同じ
    /// 経路）。`Accept-Language: en` を付けると、その本文の message が英語（日本語を含まない）になる。
    @Test func unsupportedFormatMessageIsEnglishWithAcceptLanguageEn() async throws {
        let fixture = try TestLibraryFixture(name: "CRUNSUP-EN", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addUnsupportedFormatBook(extension: "txt")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover/regenerate",
                method: .post,
                headers: [.authorization: "Bearer W", .acceptLanguage: "en"]
            ) { response in
                #expect(response.status == .badRequest)
                let body = String(buffer: response.body)
                #expect(body.contains("doesn't support automatic cover generation"))
                #expect(!containsJapanese(body))
            }
        }
    }

    /// 同じエンドポイントで `Accept-Language: ja` を明示すると日本語のままであることの対比確認
    /// （ヘッダを付けない場合はここでは検証していない）。
    @Test func unsupportedFormatMessageIsJapaneseWithAcceptLanguageJa() async throws {
        let fixture = try TestLibraryFixture(name: "CRUNSUP-JA", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addUnsupportedFormatBook(extension: "txt")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover/regenerate",
                method: .post,
                headers: [.authorization: "Bearer W", .acceptLanguage: "ja"]
            ) { response in
                #expect(response.status == .badRequest)
                let body = String(buffer: response.body)
                #expect(containsJapanese(body))
            }
        }
    }

    private func containsJapanese(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value)
        }
    }
}
