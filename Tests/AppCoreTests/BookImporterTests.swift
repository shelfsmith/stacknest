// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryStore
@testable import AppCore

@Suite("BookImporter")
struct BookImporterTests {
    private func makeImporter() throws -> (BookImporter, Database, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openInMemory()
        try db.migrate()
        let fmt = try FilenameFormat(raw: "@title")
        let importer = BookImporter(database: db, bundleURL: dir, format: fmt)
        return (importer, db, dir)
    }

    @Test func addsSingleImageAndSkipsDuplicatePath() async throws {
        let (importer, db, dir) = try makeImporter()
        let png = dir.appendingPathComponent("sample.png")
        try Self.onePixelPNG().write(to: png)

        let r1 = await importer.add(urls: [png], autoClassifyEnabled: false, thickThreshold: 100)
        #expect(r1.addedIDs.count == 1)
        #expect(try db.fetchAllBooks().count == 1)

        let r2 = await importer.add(urls: [png], autoClassifyEnabled: false, thickThreshold: 100)
        #expect(r2.addedIDs.isEmpty)
        #expect(r2.alreadyPresent == [png])
        #expect(try db.fetchAllBooks().count == 1)
    }

    @Test func nonexistentPathIsFailedNotAdded() async throws {
        let (importer, db, dir) = try makeImporter()
        let ghost = dir.appendingPathComponent("does-not-exist.cbz")
        let r = await importer.add(urls: [ghost], autoClassifyEnabled: false, thickThreshold: 100)
        #expect(r.addedIDs.isEmpty)
        #expect(r.failed.count == 1)
        #expect(r.failed.first?.0 == ghost)
        #expect(try db.fetchAllBooks().count == 0)
    }

    private static func onePixelPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
    }

    // G9b Task2: archive モードの列挙結果（ディレクトリ候補）が BookImporter に渡ると、
    // 既存のフォルダ本取込経路（isDir → fileType=folder・FolderCoverExtractor で表紙）で
    // "1 ディレクトリ = 1 冊" として insert されることをエンドツーエンドで確認する。
    // topLevelOnly では同じ木からディレクトリ候補が一切出ない（=取り込まれない）ことも合わせて確認する。
    @Test func archiveModeImportsSubdirectoryAsOneBookViaEnumerateCandidates() async throws {
        let (importer, db, watchRoot) = try makeImporter()
        // watchRoot 自体を監視フォルダとして使う（bundleURL としても使い回すが Thumbnails は別物なので問題ない）。
        let sub = watchRoot.appendingPathComponent("VolumeA", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Self.onePixelPNG().write(to: sub.appendingPathComponent("page01.png"))
        try Data("plain".utf8).write(to: watchRoot.appendingPathComponent("loose.txt"))

        // archive: 直下サブフォルダ(VolumeA)を1候補＋トップレベル素ファイル(loose.txt)。孫(page01.png)は候補に出ない。
        let archiveCandidates = WatchFolderScanner.enumerateCandidates(folder: watchRoot, mode: .archive)
        let archiveNames = Set(archiveCandidates.map { $0.lastPathComponent })
        #expect(archiveNames.contains("VolumeA"))
        #expect(archiveNames.contains("loose.txt"))
        #expect(!archiveNames.contains("page01.png"))

        // NB: `sub` (constructed via appendingPathComponent from temporaryDirectory) and the URL
        // FileManager.contentsOfDirectory(at:) hands back can differ textually on macOS
        // (/var/... vs the symlink-resolved /private/var/...), even though they name the same
        // directory. Import/dedup only ever compares candidate-URL.path to candidate-URL.path
        // (never to an independently-constructed URL), so that's not a real bug — but it means
        // this test must look up the expected path from the *candidate itself*, not from `sub`.
        guard let dirCandidate = archiveCandidates.first(where: { $0.lastPathComponent == "VolumeA" }) else {
            Issue.record("expected an archive candidate for the VolumeA subdirectory")
            return
        }

        let archiveResult = await importer.add(urls: archiveCandidates, autoClassifyEnabled: false, thickThreshold: 100)
        #expect(archiveResult.addedIDs.count == 2)   // VolumeA(フォルダ本) + loose.txt
        let books = try db.fetchAllBooks()
        guard let folderBook = books.first(where: { $0.path == dirCandidate.path }) else {
            Issue.record("expected one book with path == subfolder candidate path (folder-as-one-book)")
            return
        }
        #expect(folderBook.title == "VolumeA")      // basename がそのままタイトルに
        #expect(folderBook.fileType == 4)           // FileTypeCode.folder
        #expect(folderBook.pages == 1)              // FolderCoverExtractor が VolumeA 直下の1枚を検出
        #expect(!archiveResult.coverFailures.contains(dirCandidate))   // フォルダ本の表紙抽出は成功（loose.txt は非対応拡張子で失敗して構わない）
        #expect(try db.fetchAllBooks().count == 2)

        // topLevelOnly: 同じ木で candidate を取り直すと、サブフォルダは一切出ない＝取り込まれない。
        let topLevelCandidates = WatchFolderScanner.enumerateCandidates(folder: watchRoot, mode: .topLevelOnly)
        let topLevelNames = Set(topLevelCandidates.map { $0.lastPathComponent })
        #expect(!topLevelNames.contains("VolumeA"))
        #expect(topLevelNames.contains("loose.txt"))
    }

    // Codex Finding 3: サイズ>0 でも importable な画像が1枚も無いディレクトリ（テキストのみ）は
    // 0-page book として insert してはいけない。dedup が path ベースのため、insert してしまうと
    // 後から本物のページを追加しても二度と再取込されない永久破損 book になる。
    // このテストは「拒否される」ことに加え、「拒否した path が DB に一切記録されず、後で本物の
    // 画像が追加された同じ path を再度 add すればちゃんと取り込まれる」ことまで確認する
    // （ゲートを無くすと 1 回目で insert されてしまい、2 回目が alreadyPresent で弾かれて
    // addedIDs が空のままになる＝この assert が FAIL する）。
    @Test func folderWithNoImportablePagesIsNotImportedAndCanBeRetriedLater() async throws {
        let (importer, db, dir) = try makeImporter()
        let sub = dir.appendingPathComponent("EmptyVol", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("just text, no images here".utf8).write(to: sub.appendingPathComponent("readme.txt"))

        let r1 = await importer.add(urls: [sub], autoClassifyEnabled: false, thickThreshold: 100)
        #expect(r1.addedIDs.isEmpty)
        #expect(r1.failed.count == 1)
        #expect(r1.failed.first?.0 == sub)
        #expect(try db.fetchAllBooks().count == 0)   // 誰も DB に記録されていない = dedup を汚さない

        // 後から本物の画像が追加された同じフォルダは、再取込で今度こそ成功しなければならない。
        try Self.onePixelPNG().write(to: sub.appendingPathComponent("page01.png"))
        let r2 = await importer.add(urls: [sub], autoClassifyEnabled: false, thickThreshold: 100)
        #expect(r2.addedIDs.count == 1)
        #expect(try db.fetchAllBooks().count == 1)
    }

    // Codex Finding 3 バリエーション: 直下に画像が無く、孫階層にのみ画像があるディレクトリも
    // 同様に拒否されること（FolderCoverExtractor はサブディレクトリを辿らない仕様なので、
    // 直下 0 件＝importable page 0 件として扱われるべき）。
    @Test func folderWithOnlyNestedSubdirectoryImagesIsNotImported() async throws {
        let (importer, db, dir) = try makeImporter()
        let sub = dir.appendingPathComponent("NestedOnly", isDirectory: true)
        let nested = sub.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Self.onePixelPNG().write(to: nested.appendingPathComponent("page01.png"))

        let r = await importer.add(urls: [sub], autoClassifyEnabled: false, thickThreshold: 100)
        #expect(r.addedIDs.isEmpty)
        #expect(r.failed.count == 1)
        #expect(try db.fetchAllBooks().count == 0)
    }

    // 対照: アーカイブ*ファイル*（ディレクトリではない）は本 Finding のスコープ外——
    // 既存の loose.txt 相当の挙動（0-page でも insert される）を変えていないことの確認。
    @Test func nonDirectoryFileWithoutImportablePagesIsStillImported() async throws {
        let (importer, db, dir) = try makeImporter()
        let txt = dir.appendingPathComponent("loose.txt")
        try Data("plain".utf8).write(to: txt)

        let r = await importer.add(urls: [txt], autoClassifyEnabled: false, thickThreshold: 100)
        #expect(r.addedIDs.count == 1)
        #expect(try db.fetchAllBooks().count == 1)
    }

    // G26 Import gate fixup: TruncatedReadPolicy の「打ち切り読みから出た数値は DB に書かない」を
    // import 経路にも適用したことの確認。DamagedZipFixture は 6 枚中 3 枚目のローカルヘッダを壊した
    // zip を作る（LibarchiveCoverExtractor は ARCHIVE_FATAL に当たると読めた分＝2 枚を truncated=true
    // で返す）。この count をそのまま書くと books.pages=2 になり、13/40 ページ本の smoke で見つかった
    // 不具合（読了と誤認・pages IS NULL クエリから漏れる）を再現してしまう。
    @Test func damagedArchiveImportDoesNotRecordATruncatedPageCount() async throws {
        let (importer, db, dir) = try makeImporter()
        let zipURL = dir.appendingPathComponent("damaged.zip")
        try DamagedZipFixture.makeDamagedZip().write(to: zipURL)

        let r = await importer.add(urls: [zipURL], autoClassifyEnabled: false, thickThreshold: 100)
        #expect(r.addedIDs.count == 1)
        let books = try db.fetchAllBooks()
        guard let book = books.first(where: { $0.path == zipURL.path }) else {
            Issue.record("expected the damaged zip to be imported as a book")
            return
        }
        // 打ち切り読みからの数値は一切残らない — 0 でも読めた分の数でもなく nil であること
        // (nil は「pages IS NULL」の follow-up 機能が破損本を見つけるための足場でもある)。
        #expect(book.pages == nil)
        // カバー抽出は読めた分（3 枚目より手前）から続行できているはず。
        #expect(!r.coverFailures.contains(zipURL))
    }
}
