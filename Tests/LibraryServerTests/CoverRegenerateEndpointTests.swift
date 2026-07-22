// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import AppCore
import LibraryServerAPI
import LibraryStore
@testable import LibraryServer

/// G21 #5: 1 冊単位の表紙再生成エンドポイント、および relink 時の表紙/ページ数追従の回帰テスト。
@Suite("cover regenerate endpoint")
struct CoverRegenerateEndpointTests {
    private func makeApp(_ lib: ServedLibrary) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W"),
            dataSource: StaticLibraryDataSource(libraries: [lib])
        ).buildApplication()
    }

    /// POST cover/regenerate は auto カバーの本の thumbnail.jpg を実際に作る。
    @Test func regeneratesCoverForAutoCoverBook() async throws {
        let fixture = try TestLibraryFixture(name: "CR", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "three_pages")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        let thumb = fixture.bundleURL
            .appendingPathComponent("Thumbnails/\(bookID)/thumbnail.jpg")
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover/regenerate",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(FileManager.default.fileExists(atPath: thumb.path))   // 生成されている
    }

    /// R トークン（読み取り専用）は 403。
    @Test func regenerateRequiresWrite() async throws {
        let fixture = try TestLibraryFixture(name: "CRR2", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "three_pages")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover/regenerate",
                method: .post, headers: [.authorization: "Bearer R"]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// 外部表紙（手動アップロード相当）は regenerate で上書きされない（最も破壊的な失敗モードのガード）。
    @Test func doesNotOverwriteExternalCover() async throws {
        let fixture = try TestLibraryFixture(name: "CRX", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "three_pages")
        // 外部表紙にする（手動アップロード相当）
        var patch = BookPatch(); patch.coverImageName = CoverSource.externalSentinel
        try fixture.db.updateBook(id: bookID, patch: patch)
        let thumbDir = fixture.bundleURL.appendingPathComponent("Thumbnails/\(bookID)")
        try FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        let thumb = thumbDir.appendingPathComponent("thumbnail.jpg")
        let sentinelBytes = Data(repeating: 0xAB, count: 128)
        try sentinelBytes.write(to: thumb)

        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover/regenerate",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)   // no-op で 200（エラーにはしない）
            }
        }
        // 外部表紙は温存される（バイト列が変わらない）
        #expect(try Data(contentsOf: thumb) == sentinelBytes)
        // coverImageName も @external のまま（regenerate が誤って書き換えていないこと）
        #expect(CoverSource.isExternal(try fixture.db.fetchBook(id: bookID)?.coverImageName))
    }

    /// 手動でアーカイブ内エントリを指定した本は、regenerate 後もその同じエントリが使われる
    /// （preferredName として row.coverImageName を渡している検証）。
    @Test func regenerateHonorsManualEntryName() async throws {
        let fixture = try TestLibraryFixture(name: "CRM", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "three_pages")
        var patch = BookPatch(); patch.coverImageName = "p2.png"
        try fixture.db.updateBook(id: bookID, patch: patch)
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/cover/regenerate",
                method: .post, headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
        // coverImageName は手動指定のまま変わらない（regenerate は再抽出するだけで
        // 指定を上書き/クリアしない）。
        #expect(try fixture.db.fetchBook(id: bookID)?.coverImageName == "p2.png")
    }

    // MARK: - Step 6: relink 連動の回帰テスト

    /// relink すると自動表紙（coverImageName == nil）が新ファイルから作り直され（mtime 更新）、
    /// ページ数も新ファイルの実数に更新される。
    @Test func relinkRegeneratesAutoCoverAndUpdatesPageCount() async throws {
        let fixture = try TestLibraryFixture(name: "CRRL", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "two_pages")
        try fixture.addCover(bookID: bookID)   // 旧ファイル由来の初期表紙（プレースホルダ）
        let lib = fixture.servedLibrary()
        let thumb = lib.bundleURL.appendingPathComponent("Thumbnails/\(bookID)/thumbnail.jpg")
        // 明確に古い mtime へバックデートしておき、relink 後に更新されたことを検出できるようにする。
        let oldDate = Date(timeIntervalSince1970: 0)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: thumb.path)

        let app = makeApp(lib)
        guard let src = Bundle.module.url(
            forResource: "three_pages", withExtension: "zip", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dst = lib.bundleURL.appendingPathComponent("relinked-three.zip")
        try FileManager.default.copyItem(at: src, to: dst)
        let body = try JSONEncoder().encode(RelinkRequest(newPath: dst.path))

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/relink",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { response in
                #expect(response.status == .noContent)
            }
        }

        #expect(try fixture.db.fetchBook(id: bookID)?.pages == 3)   // three_pages.zip の実ページ数
        let newMtime = (try FileManager.default.attributesOfItem(atPath: thumb.path)[.modificationDate]) as? Date
        #expect(newMtime != nil && newMtime! > oldDate)
    }

    /// 外部表紙の本を relink しても、サムネイルは変わらない（表紙は温存）。
    /// ページ数だけは新ファイルの実数に更新される。
    @Test func relinkPreservesExternalCoverButStillUpdatesPageCount() async throws {
        let fixture = try TestLibraryFixture(name: "CRRLX", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "two_pages")
        var patch = BookPatch(); patch.coverImageName = CoverSource.externalSentinel
        try fixture.db.updateBook(id: bookID, patch: patch)
        let lib = fixture.servedLibrary()
        let thumbDir = lib.bundleURL.appendingPathComponent("Thumbnails/\(bookID)")
        try FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        let thumb = thumbDir.appendingPathComponent("thumbnail.jpg")
        let sentinelBytes = Data(repeating: 0xCD, count: 96)
        try sentinelBytes.write(to: thumb)

        let app = makeApp(lib)
        guard let src = Bundle.module.url(
            forResource: "three_pages", withExtension: "zip", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dst = lib.bundleURL.appendingPathComponent("relinked-three-ext.zip")
        try FileManager.default.copyItem(at: src, to: dst)
        let body = try JSONEncoder().encode(RelinkRequest(newPath: dst.path))

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/relink",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { response in
                #expect(response.status == .noContent)
            }
        }

        #expect(try Data(contentsOf: thumb) == sentinelBytes)   // 表紙は不変
        #expect(try fixture.db.fetchBook(id: bookID)?.pages == 3)   // ページ数は追従する
    }

    /// relink 先のファイルがそもそも抽出不能でも（best-effort）relink 自体は成功する。
    @Test func relinkSucceedsEvenIfCoverExtractionWouldFail() async throws {
        let fixture = try TestLibraryFixture(name: "CRRLF", bookCount: 0)
        defer { fixture.cleanup() }
        let bookID = try fixture.addRealBook(zipFixtureNamed: "two_pages")
        let lib = fixture.servedLibrary()
        let app = makeApp(lib)
        // 存在しないファイルへ relink（抽出もページ数取得も失敗するはず）。
        let missingPath = lib.bundleURL.appendingPathComponent("does-not-exist.zip").path
        let body = try JSONEncoder().encode(RelinkRequest(newPath: missingPath))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(bookID)/relink",
                method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(body))
            ) { response in
                #expect(response.status == .noContent)   // relink 自体は成功扱い
            }
        }
        #expect(try fixture.db.fetchBook(id: bookID)?.path == missingPath)
    }
}
