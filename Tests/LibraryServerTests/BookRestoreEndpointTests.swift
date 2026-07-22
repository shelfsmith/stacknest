// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import AppCore
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

    private func makeApp(
        fixture: TestLibraryFixture, adminTier: Bool,
        trashFile: (@Sendable (URL) throws -> URL?)? = nil
    ) -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", trashFile: trashFile, adminTier: adminTier),
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
                #expect(response.status == .ok)
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
            #expect(dto.hasCover == true)                                // 削除時点の表紙有無を捕捉
            #expect(!FileManager.default.fileExists(atPath: thumb.path)) // DELETE がサムネを消した

            let encoded = try JSONEncoder().encode([dto])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .ok)
            }
        }
        // restore がサムネイルを再生成した（ローカル undo と同じ結果）。
        #expect(FileManager.default.fileExists(atPath: thumb.path))
    }

    /// re-review Critical regression test: 外部表紙（`@external`）の本を削除→Undo（restore）すると、
    /// DELETE が `Thumbnails/<id>` を丸ごと消すため、restore 時点では行が `@external` のまま
    /// サムネイルファイルだけが存在しない。この状態で `regenerateThumbnail` の外部表紙ガードが
    /// 「isExternal というだけで無条件 no-op」だと、恒久的に無表紙のまま直せなくなる
    /// （regenerate は外部表紙に no-op、CoverCompression も外部表紙をスキップ、UI のメニューも
    /// 無効化されるため）。ガードは「isExternal かつファイルが現存する」ときだけ no-op にすべきで、
    /// このケース（ファイル不在）はソースアーカイブから自動表紙を作り直して復帰する必要がある。
    @Test func restoreRegeneratesAutoThumbnailWhenExternalCoverWasDeleted() async throws {
        let fx = try TestLibraryFixture(name: "RestoreExtCover", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let id = try fx.addRealBook(zipFixtureNamed: "three_pages")
        // アップロード済み外部表紙を模す: coverImageName=@external ＋ 実サムネイルファイル配置。
        try fx.db.updateBook(id: id, patch: BookPatch(coverImageName: CoverSource.externalSentinel))
        try fx.addCover(bookID: id)
        let thumb = coverURL(bundleURL: fx.bundleURL, bookID: id)
        #expect(FileManager.default.fileExists(atPath: thumb.path))   // 前提: 表紙あり（外部）

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
            #expect(dto.hasCover == true)
            #expect(dto.coverImageName == CoverSource.externalSentinel)     // 外部表紙のまま捕捉
            #expect(!FileManager.default.fileExists(atPath: thumb.path))   // DELETE がサムネを消した

            let encoded = try JSONEncoder().encode([dto])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .ok)
            }
        }
        // restore 後: 行は @external のままだが（アップロードされた画像自体はもう無いので取り戻せない
        // ことは仕方ないが）、恒久的に無表紙のままにはせず、ソースから自動表紙を作り直して
        // 表紙が「ある」状態に復帰する（ファイル存在チェックを外した旧修正だとここが false のまま
        // 永遠に直らなかった）。
        #expect(FileManager.default.fileExists(atPath: thumb.path))
        #expect(try fx.db.fetchBook(id: id)?.coverImageName == CoverSource.externalSentinel)
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
            #expect(dto.hasCover != true)

            let encoded = try JSONEncoder().encode([dto])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .ok)
            }
        }
        // 表紙を勝手に生成していない。
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
    }

    /// Codex G12b-3d Medium: hasCover キーを持たない旧ペイロードでも restore が decode 成功し
    /// 本が復元される（後方互換＝欠落は無表紙扱いの安全側）。表紙は再生成されない。
    @Test func restoreDecodesPayloadWithoutHasCover() async throws {
        let fx = try TestLibraryFixture(name: "RestoreBackcompat", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let id = try fx.addRealBook(zipFixtureNamed: "three_pages")
        let beforeOpt = try fx.db.fetchBook(id: id)
        let before = try #require(beforeOpt)
        let thumb = coverURL(bundleURL: fx.bundleURL, bookID: id)

        let app = makeApp(fixture: fx, adminTier: true)
        try await app.test(.router) { client in
            // 本を消す（DB のみ）。
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)", method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in #expect(response.status == .ok) }
            #expect(try fx.db.fetchBook(id: id) == nil)

            // hasCover を含まない手組み JSON（旧クライアント相当）で restore。
            let legacyJSON = """
            [{"id":\(id),"title":\(jsonString(before.title)),"path":\(jsonString(before.path ?? "")),\
            "dateAdded":\(before.dateAdded.timeIntervalSince1970),"bookType":\(before.bookType),\
            "fileType":\(before.fileType),"rating":\(before.rating),"unseen":\(before.unseen)}]
            """
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: ByteBuffer(string: legacyJSON)
            ) { response in
                #expect(response.status == .ok)   // decode 失敗せず復元成立
            }
        }
        #expect(try fx.db.fetchBook(id: id) != nil)                    // 復元された
        #expect(!FileManager.default.fileExists(atPath: thumb.path))   // 欠落=無表紙扱い→表紙生成せず
    }

    /// JSON 文字列リテラル用の最小エスケープ（テストデータは英数字のみのため十分）。
    private func jsonString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
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

    // MARK: - G16 A1: restore 応答の restored/requested 件数

    /// 2 件を restore に渡し、1 件が id 衝突（restoreBook の plain-INSERT UNIQUE 違反）でスキップされる状況で
    /// 応答が RestoreResultDTO{restored:1, requested:2} になること（衝突側の既存行は上書きされない）。
    @Test func restoreReturnsRestoredCountWhenOneRowCollides() async throws {
        let fx = try TestLibraryFixture(name: "RestoreCount", bookCount: 2)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let app = makeApp(fixture: fx, adminTier: true)

        // id=1 は削除せず現存させたまま「衝突させる DTO」を手組みする（restoreBook は plain INSERT
        // なので、既に行が存在する id へ復元しようとすると UNIQUE 制約違反でスキップされる）。
        let existingRow = try #require(try fx.db.fetchBook(id: 1))
        let collidingDTO = BookRestoreDTO(
            id: existingRow.id, title: existingRow.title, author: existingRow.author,
            genre: existingRow.genre, path: existingRow.path,
            dateAdded: existingRow.dateAdded.timeIntervalSince1970,
            playDate: existingRow.playDate?.timeIntervalSince1970,
            bookType: existingRow.bookType, fileType: existingRow.fileType, pages: existingRow.pages,
            rating: existingRow.rating, unseen: existingRow.unseen,
            keywordA: existingRow.keywordA, keywordB: existingRow.keywordB, keywordC: existingRow.keywordC,
            neta: existingRow.neta, memo: existingRow.memo, series: existingRow.series, volume: existingRow.volume,
            coverImageName: existingRow.coverImageName
        )

        // id=2 は実際に削除して DTO を捕捉する（こちらは衝突なく復元されるはず）。
        nonisolated(unsafe) var deletedDTO: BookRestoreDTO?
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/2", method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
                deletedDTO = try JSONDecoder().decode(BookRestoreDTO.self, from: Data(buffer: response.body))
            }
            let dto2 = try #require(deletedDTO)

            let encoded = try JSONEncoder().encode([collidingDTO, dto2])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .ok)
                let result = try JSONDecoder().decode(RestoreResultDTO.self, from: Data(buffer: response.body))
                #expect(result.restored == 1)
                #expect(result.requested == 2)
                // G16 Codex Critical: restoredIDs は実際に復元できた id（衝突しなかった id=2）だけを
                // 含む。衝突でスキップされた id=1 は含まれない（redo が id=1 を誤って再削除しない
                // ための土台）。
                #expect(result.restoredIDs == [2])
            }
        }
        // id=2 は復元され、id=1 は元のまま（衝突側は上書きされていない）。
        #expect(try fx.db.fetchBook(id: 2) != nil)
        #expect(try fx.db.fetchBook(id: 1) != nil)
    }

    // MARK: - G16 A3: trash undo のファイル復元（セキュリティ修正後: サーバー側 trashTracker のみで動く）

    /// trashFile スタブ（渡された URL を temp のゴミ箱擬似 dir へ move し resultingItemURL を返す）を注入し、
    /// trash 削除 → サーバーが trashTracker に記録 → restore で元の path へファイルが戻ることを確認する。
    /// BookRestoreDTO はもう trashedPath を持たない（クライアントにゴミ箱パスを渡さない＝セキュリティ修正）ので、
    /// テスト側はスタブの命名規則（trashDir + lastPathComponent）から期待されるゴミ箱パスを独自に計算する。
    @Test func trashUndoRestoresFileFromTrash() async throws {
        let fx = try TestLibraryFixture(name: "RestoreTrashFile", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let id = try fx.addRealBook(zipFixtureNamed: "three_pages")
        let originalRow = try #require(try fx.db.fetchBook(id: id))
        let originalPath = try #require(originalRow.path)

        let trashDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsrv-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trashDir) }
        let app = makeApp(fixture: fx, adminTier: true, trashFile: { url in
            let dest = trashDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
        // スタブの命名規則から、実際に move された先のパスをテスト側で独立に計算する
        // （もう DTO 経由でサーバーから教えてもらわない＝クライアント供給パスを信用しない修正の裏返し）。
        let expectedTrashedPath = trashDir.appendingPathComponent((originalPath as NSString).lastPathComponent).path

        nonisolated(unsafe) var captured: BookRestoreDTO?
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)?trash=true", method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
                captured = try JSONDecoder().decode(BookRestoreDTO.self, from: Data(buffer: response.body))
            }
            let dto = try #require(captured)
            #expect(FileManager.default.fileExists(atPath: expectedTrashedPath))  // ゴミ箱側へ移動済み
            #expect(!FileManager.default.fileExists(atPath: originalPath))        // 元の場所からは消えた

            let encoded = try JSONEncoder().encode([dto])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .ok)
                let result = try JSONDecoder().decode(RestoreResultDTO.self, from: Data(buffer: response.body))
                #expect(result.restored == 1)
                #expect(result.requested == 1)
            }
        }
        // restore がファイルを元の場所へ移動し戻した（ゴミ箱側にはもう残っていない）。
        #expect(FileManager.default.fileExists(atPath: originalPath))
        #expect(!FileManager.default.fileExists(atPath: expectedTrashedPath))
    }

    /// セキュリティレビュー Important (a): restore 実行時点で原本パスに「別の新しいファイル」が
    /// 既に存在する場合、trashTracker 経由の move はそれを上書きしない（destファイル存在ガードは
    /// サーバー内部の originalPath 記録で判定される。dto.path をクライアントが書き換えても無意味）。
    /// DB 行自体は復元される（ファイル move の可否と DB 復元は独立＝degraded-safe）。
    @Test func trashUndoDoesNotOverwriteExistingFileAtOriginalPath() async throws {
        let fx = try TestLibraryFixture(name: "RestoreTrashDestOccupied", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let id = try fx.addRealBook(zipFixtureNamed: "three_pages")
        let originalRow = try #require(try fx.db.fetchBook(id: id))
        let originalPath = try #require(originalRow.path)

        let trashDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsrv-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trashDir) }
        let app = makeApp(fixture: fx, adminTier: true, trashFile: { url in
            let dest = trashDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })

        nonisolated(unsafe) var captured: BookRestoreDTO?
        let sentinelContents = Data("sentinel-do-not-overwrite".utf8)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)?trash=true", method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
                captured = try JSONDecoder().decode(BookRestoreDTO.self, from: Data(buffer: response.body))
            }
            let dto = try #require(captured)
            #expect(!FileManager.default.fileExists(atPath: originalPath))   // trash 済みで空いている

            // restore の前に、原本パスへ「新しい別ファイル」が置かれる（正当な再作成などを模す）。
            try sentinelContents.write(to: URL(fileURLWithPath: originalPath))

            let encoded = try JSONEncoder().encode([dto])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .ok)
                let result = try JSONDecoder().decode(RestoreResultDTO.self, from: Data(buffer: response.body))
                #expect(result.restored == 1)   // DB 行は復元される
            }
        }
        // 原本パスの新しいファイルは上書きされていない（内容が生き残る）。
        let survivingContents = try Data(contentsOf: URL(fileURLWithPath: originalPath))
        #expect(survivingContents == sentinelContents)
        // DB 行は復元されている（ファイル move の可否と DB 復元は独立）。
        #expect(try fx.db.fetchBook(id: id) != nil)
    }

    /// セキュリティレビュー Important (b): trashTracker に記録された trashed ファイルが restore 前に
    /// 消えている（例: サーバー再起動でトラッカーが空になる状況を模して、記録の裏付けとなる実ファイルが
    /// 無い状態）場合でも restore はクラッシュせず、DB 行の復元だけが degraded-safe に成立する。
    @Test func trashUndoRestoresDBRowWhenTrashedFileMissing() async throws {
        let fx = try TestLibraryFixture(name: "RestoreTrashFileMissing", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let id = try fx.addRealBook(zipFixtureNamed: "three_pages")
        let originalRow = try #require(try fx.db.fetchBook(id: id))
        let originalPath = try #require(originalRow.path)

        let trashDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsrv-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trashDir) }
        let app = makeApp(fixture: fx, adminTier: true, trashFile: { url in
            let dest = trashDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
        let expectedTrashedPath = trashDir.appendingPathComponent((originalPath as NSString).lastPathComponent).path

        nonisolated(unsafe) var captured: BookRestoreDTO?
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(id)?trash=true", method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
                captured = try JSONDecoder().decode(BookRestoreDTO.self, from: Data(buffer: response.body))
            }
            let dto = try #require(captured)
            #expect(FileManager.default.fileExists(atPath: expectedTrashedPath))

            // 記録済みのゴミ箱ファイルを restore 前に消してしまう（トラッカーの記録が「もう裏付けの
            // 無い」状態＝ファイル欠損 or サーバー再起動後の再現に相当）。
            try FileManager.default.removeItem(atPath: expectedTrashedPath)

            let encoded = try JSONEncoder().encode([dto])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .ok)   // クラッシュせず 200
                let result = try JSONDecoder().decode(RestoreResultDTO.self, from: Data(buffer: response.body))
                #expect(result.restored == 1)      // DB 行は復元される
            }
        }
        #expect(try fx.db.fetchBook(id: id) != nil)
        #expect(!FileManager.default.fileExists(atPath: originalPath))   // ファイルは戻ってきていない（正常）
    }

    // MARK: - G16 Codex High: restore の path 検証（許可ルート／deletedPathTracker）

    /// 正当な delete→undo: addRealBook の path はライブラリバンドル配下（許可ルートの一つ）。
    /// 同一セッションでの delete→restore は deletedPathTracker の記録とも一致するため、
    /// path 検証を追加しても path・表紙とも完全に復元される（回帰なし）。
    @Test func restorePreservesPathForRealBookWithinBundleTree() async throws {
        let fx = try TestLibraryFixture(name: "RestoreRootsLegit", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let id = try fx.addRealBook(zipFixtureNamed: "three_pages")
        try fx.db.updateBook(id: id, patch: BookPatch(coverImageName: "p10.png"))
        try fx.addCover(bookID: id)
        let beforeOpt = try fx.db.fetchBook(id: id)
        let before = try #require(beforeOpt)
        let originalPath = try #require(before.path)

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
            let encoded = try JSONEncoder().encode([dto])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .ok)
                let result = try JSONDecoder().decode(RestoreResultDTO.self, from: Data(buffer: response.body))
                #expect(result.restoredIDs == [id])
            }
        }
        let afterOpt = try fx.db.fetchBook(id: id)
        let after = try #require(afterOpt)
        // path 検証を通過し、path も表紙もそのまま復元されている（回帰なし）。
        #expect(after.path == originalPath)
        let thumb = coverURL(bundleURL: fx.bundleURL, bookID: id)
        #expect(FileManager.default.fileExists(atPath: thumb.path))
    }

    /// セキュリティ修正 (FIX2): 未使用 id ＋ ライブラリの許可ルート外（監視フォルダでもバンドル
    /// ツリーでも既存本のディレクトリでもない・deletedPathTracker にも記録が無い）path を持つ
    /// 捏造 DTO を restore しても、DB 行は復元されるが path は落とされ（neutralize）、
    /// regenerateThumbnail（アーカイブオープン）は起きない。さらに、その後の
    /// `DELETE ?trash=true` がこの行の実ファイルを一切移動できないことを、trashFile スタブの
    /// 呼び出し有無で確認する（Arbitrary File Move via Client-Controlled Paths の再発防止）。
    @Test func restoreNeutralizesFabricatedOutOfRootPath() async throws {
        let fx = try TestLibraryFixture(name: "RestoreRootsFabricated", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()

        // ライブラリバンドルの外側・監視フォルダでもない一時ディレクトリに「被害者ファイル」を置く。
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsrv-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        guard let fixtureZip = Bundle.module.url(forResource: "three_pages", withExtension: "zip", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let victimPath = outsideDir.appendingPathComponent("victim.zip")
        try FileManager.default.copyItem(at: fixtureZip, to: victimPath)

        let fabricatedID = 999
        let dto = BookRestoreDTO(
            id: fabricatedID, title: "Fabricated", author: nil, genre: nil,
            path: victimPath.path,
            dateAdded: Date().timeIntervalSince1970, playDate: nil,
            bookType: 0, fileType: 2, pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil,
            neta: nil, memo: nil, series: nil, volume: nil,
            coverImageName: nil, hasCover: true)

        nonisolated(unsafe) var trashFileCalled = false
        let app = makeApp(fixture: fx, adminTier: true, trashFile: { url in
            trashFileCalled = true
            let dest = outsideDir.appendingPathComponent("trashed-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
        try await app.test(.router) { client in
            let encoded = try JSONEncoder().encode([dto])
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/restore", method: .post,
                headers: [.authorization: "Bearer W", .contentType: "application/json"],
                body: .init(bytes: Array(encoded))
            ) { response in
                #expect(response.status == .ok)
                let result = try JSONDecoder().decode(RestoreResultDTO.self, from: Data(buffer: response.body))
                #expect(result.restoredIDs == [fabricatedID])   // DB 行は復元される（path は落ちる）
            }

            // path が neutralize されている（DB に victimPath が書き戻っていない）。
            let row = try #require(try fx.db.fetchBook(id: fabricatedID))
            #expect(row.path == nil)
            // hasCover==true だったが、path 未検証のためサムネイル再生成は起きていない。
            let thumb = coverURL(bundleURL: fx.bundleURL, bookID: fabricatedID)
            #expect(!FileManager.default.fileExists(atPath: thumb.path))

            // 後続の trash 削除がこの行の実ファイルを一切移動できない（path が nil のため
            // trashFile 自体が呼ばれない＝任意ファイル移動の芽が完全に断たれている）。
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/books/\(fabricatedID)?trash=true", method: .delete,
                headers: [.authorization: "Bearer W"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(!trashFileCalled)
        #expect(FileManager.default.fileExists(atPath: victimPath.path))   // 被害者ファイルは無傷
    }
}
