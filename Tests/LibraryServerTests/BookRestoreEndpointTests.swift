// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import StackroomFormat
@testable import LibraryServer

/// G12b-3c S5: リモート undo（削除→復元）。
/// DELETE libraries/:lib/books/:id は 200＋BookRestoreDTO を返し、
/// POST libraries/:lib/books/restore（admin）は捕捉した BookRestoreDTO を再挿入して本を復元する。
@Suite("BookRestore endpoint")
struct BookRestoreEndpointTests {
    // MARK: - helpers

    private func makeApp(fixture: TestLibraryFixture, adminTier: Bool) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        ).buildApplication()
    }

    // MARK: - 基本往復（brief Step 1 骨子）

    /// DELETE(trash=false) → 200＋BookRestoreDTO・本が消える。
    /// 捕捉した DTO を POST restore に渡すと本が id を保ったまま復活し、
    /// 主要フィールド（title/rating/series/volume）が生き残る。
    @Test func deleteReturnsRowAndRestoreReinserts() async throws {
        let fx = try TestLibraryFixture(name: "Restore", bookCount: 1)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let allBooks = try fx.db.fetchAllBooks()
        let id = try #require(allBooks.first?.id)
        let beforeOpt = try fx.db.fetchBook(id: id)
        let before = try #require(beforeOpt)
        let app = makeApp(fixture: fx, adminTier: true)

        nonisolated(unsafe) var captured: BookRestoreDTO?
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)", method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
                captured = try JSONDecoder().decode(BookRestoreDTO.self, from: Data(buffer: response.body))
            }

            #expect(try fx.db.fetchBook(id: id) == nil)   // 消えた

            let dto = try #require(captured)
            #expect(dto.id == id)
            let encoded = try JSONEncoder().encode([dto])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .noContent)
            }
        }

        let afterOpt = try fx.db.fetchBook(id: id)
        let after = try #require(afterOpt)   // 戻った・同じ id
        #expect(after.id == before.id)
        #expect(after.title == before.title)
        #expect(after.rating == before.rating)
        #expect(after.series == before.series)
        #expect(after.volume == before.volume)
    }

    // MARK: - G12b-3d smoke fix: 表紙サムネイルの復元（ローカル undo と parity）

    /// 削除時に表紙があった本は、restore で Thumbnails/<id>/thumbnail.jpg が
    /// ソースアーカイブから再生成される（DELETE が消したサムネを undo で戻す）。
    @Test func restoreRegeneratesThumbnailWhenBookHadCover() async throws {
        let fx = try TestLibraryFixture(name: "RestoreCover", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let id = try fx.addRealBook(zipFixtureNamed: "three_pages")
        // 手動表紙（アーカイブ内エントリ）を選択記録し、サムネイルを配置＝削除時 hasCover=true。
        try fx.db.updateBook(id: id, patch: BookPatch(coverImageName: "p10.png"))
        try fx.addCover(bookID: id)
        let thumb = coverURL(bundleURL: fx.bundleURL, bookID: id)
        #expect(FileManager.default.fileExists(atPath: thumb.path))   // 前提: 表紙あり

        let app = makeApp(fixture: fx, adminTier: true)
        nonisolated(unsafe) var captured: BookRestoreDTO?
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)", method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
                captured = try JSONDecoder().decode(BookRestoreDTO.self, from: Data(buffer: response.body))
            }
            let dto = try #require(captured)
            #expect(dto.hasCover)                                        // 削除時点の表紙有無を捕捉
            #expect(!FileManager.default.fileExists(atPath: thumb.path)) // DELETE がサムネを消した

            let encoded = try JSONEncoder().encode([dto])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .noContent)
            }
        }
        // restore がサムネイルを再生成した（ローカル undo と同じ結果）。
        #expect(FileManager.default.fileExists(atPath: thumb.path))
    }

    /// 削除時に表紙が無かった本は、restore でサムネイルを新規生成しない
    /// （無表紙本に先頭ページ表紙を勝手に付けない＝忠実性）。
    @Test func restoreDoesNotAddCoverWhenBookHadNone() async throws {
        let fx = try TestLibraryFixture(name: "RestoreNoCover", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let id = try fx.addRealBook(zipFixtureNamed: "three_pages")   // 実アーカイブだが表紙未設定
        let thumb = coverURL(bundleURL: fx.bundleURL, bookID: id)
        #expect(!FileManager.default.fileExists(atPath: thumb.path))  // 前提: 表紙なし

        let app = makeApp(fixture: fx, adminTier: true)
        nonisolated(unsafe) var captured: BookRestoreDTO?
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)", method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
                captured = try JSONDecoder().decode(BookRestoreDTO.self, from: Data(buffer: response.body))
            }
            let dto = try #require(captured)
            #expect(!dto.hasCover)

            let encoded = try JSONEncoder().encode([dto])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .noContent)
            }
        }
        // 表紙を勝手に生成していない。
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
    }

    // MARK: - admin ゲート

    /// edit トークンで books/restore → 403（本の存否に関わらず tier チェックが先）。
    @Test func restoreRequiresAdmin() async throws {
        let fx = try TestLibraryFixture(name: "RestoreForbidden", bookCount: 1)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let app = makeApp(fixture: fx, adminTier: false)   // Bearer W → tier .edit

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: ByteBuffer(string: "[]")
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    // MARK: - DTO 往復の全フィールド忠実性

    /// 全フィールドを埋めた本を削除したとき、返る BookRestoreDTO が
    /// coverCropRect（x/y/w/h）・pageDirection（"ltr"/"rtl"）・contentHash/fileSize/fileMtime を含め
    /// 削除前の行と一致すること（BookRow → BookRestoreDTO 変換ヘルパの忠実性）。
    @Test func deleteResponseDTOPreservesAllFields() async throws {
        let fx = try TestLibraryFixture(name: "RestoreFidelity", bookCount: 1)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let id = try #require(fx.db.fetchAllBooks().first?.id)

        try fx.db.updateBook(id: id, patch: BookPatch(
            author: "著者A", keywordA: "KA", keywordB: "KB", keywordC: "KC",
            genre: "ジャンル", neta: "ネタバレ", memo: "メモ", unseen: true,
            bookType: 2, coverImageName: "page03.jpg", pageDirection: .leftToRight))
        let cropRect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        try fx.db.updateBookCoverCropRect(id: id, json: BookRow.encodeCoverCropRect(cropRect))
        try fx.db.updateBookContentHash(id: id, hash: "deadbeef", size: 12345, mtime: 1_700_000_000.5)

        let beforeOpt = try fx.db.fetchBook(id: id)
        let before = try #require(beforeOpt)
        #expect(before.coverCropRect != nil)   // seed が効いていることの前提確認
        #expect(before.pageDirection == .leftToRight)
        #expect(before.contentHash == "deadbeef")

        let app = makeApp(fixture: fx, adminTier: true)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)", method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
                let dto = try JSONDecoder().decode(BookRestoreDTO.self, from: Data(buffer: response.body))
                #expect(dto.id == before.id)
                #expect(dto.title == before.title)
                #expect(dto.author == before.author)
                #expect(dto.genre == before.genre)
                #expect(dto.path == before.path)
                #expect(abs(dto.dateAdded - before.dateAdded.timeIntervalSince1970) < 0.001)
                #expect(dto.playDate == nil && before.playDate == nil)
                #expect(dto.bookType == before.bookType)
                #expect(dto.fileType == before.fileType)
                #expect(dto.pages == before.pages)
                #expect(dto.rating == before.rating)
                #expect(dto.unseen == before.unseen)
                #expect(dto.keywordA == before.keywordA)
                #expect(dto.keywordB == before.keywordB)
                #expect(dto.keywordC == before.keywordC)
                #expect(dto.neta == before.neta)
                #expect(dto.memo == before.memo)
                #expect(dto.series == before.series)
                #expect(dto.volume == before.volume)
                #expect(dto.coverImageName == before.coverImageName)
                #expect(dto.coverCropX == Double(cropRect.origin.x))
                #expect(dto.coverCropY == Double(cropRect.origin.y))
                #expect(dto.coverCropW == Double(cropRect.size.width))
                #expect(dto.coverCropH == Double(cropRect.size.height))
                #expect(dto.pageDirection == "ltr")
                #expect(dto.contentHash == "deadbeef")
                #expect(dto.fileSize == 12345)
                #expect(dto.fileMtime == 1_700_000_000.5)
            }
        }
    }
}
