// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryStore
import EPUBAdapter
@testable import AppCore

/// `EPUBAdapter.reader` はプロセス全体のグローバル。これを差し替えるテストは
/// **必ずこの親 suite の中**に置く（.serialized が入れ子に伝播して直列になる）。
/// 別ファイル・別 suite に置くと並列実行で競合する（G48-1 Task 3 修正ラウンド 1 で実際に起きた）。
@Suite("EPUBAdapter.reader を差し替えるテスト", .serialized)
struct EPUBReaderGlobalTests {
    struct StubReader: EPUBReading {
        let cover: Data?
        func open(url: URL) async throws -> EPUBBookInfo {
            EPUBBookInfo(title: "t", author: nil, language: nil, readingDirection: .unknown)
        }
        func coverImageData(url: URL, maxPixelSize: Int) async throws -> Data? { cover }
    }

    /// `CoverRefresher` が EPUB を `EPUBAdapter.reader` に回すことを、Washi に触れずに確かめる。
    @Suite("CoverRefresher の EPUB 分岐")
    struct CoverRefresherEPUB {
        private func tmpEPUB() throws -> URL {
            let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("x-\(UUID().uuidString).epub")
            try Data("zz".utf8).write(to: u)
            return u
        }

        @Test("登録された reader の表紙をそのまま返す")
        func usesRegisteredReader() async throws {
            let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
            EPUBAdapter.reader = StubReader(cover: Data([0xFF, 0xD8, 0x01]))
            let data = try await CoverRefresher.extractCoverData(sourceURL: try tmpEPUB(), preferredName: nil)
            #expect(data == Data([0xFF, 0xD8, 0x01]))
        }

        @Test("表紙の無い EPUB は noCoverImage（reader は読めているので unsupportedFormat とは区別）")
        func noCoverImage() async throws {
            let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
            EPUBAdapter.reader = StubReader(cover: nil)
            await #expect(throws: CoverRefreshError.noCoverImage) {
                _ = try await CoverRefresher.extractCoverData(sourceURL: try tmpEPUB(), preferredName: nil)
            }
        }

        @Test("未登録でもクラッシュせず unsupportedFormat")
        func unregisteredIsSafe() async throws {
            let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
            EPUBAdapter.reader = nil
            await #expect(throws: CoverRefreshError.unsupportedFormat) {
                _ = try await CoverRefresher.extractCoverData(sourceURL: try tmpEPUB(), preferredName: nil)
            }
        }
    }

    /// G48 修正ラウンド1: `BookImporter.add` の表紙生成分岐は `CoverRefresher.extractCoverData` を
    /// 通らない独自ロジック（`coverDataOverride`）。EPUB がここで表紙を作れるかをエンドツーエンドで確認する。
    @Suite("BookImporter の EPUB 表紙取り込み")
    struct BookImporterEPUBCover {
        private func makeImporter() throws -> (BookImporter, Database, URL) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bi-epub-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let db = try Database.openInMemory()
            try db.migrate()
            let fmt = try FilenameFormat(raw: "@title")
            let importer = BookImporter(database: db, bundleURL: dir, format: fmt)
            return (importer, db, dir)
        }

        @Test("表紙のある EPUB を取り込むと thumbnail.jpg が書き出される（coverFailures に落ちない）")
        func importsEPUBCover() async throws {
            let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
            let coverBytes = Data([0xFF, 0xD8, 0x02])
            EPUBAdapter.reader = StubReader(cover: coverBytes)

            let (importer, db, dir) = try makeImporter()
            let epub = dir.appendingPathComponent("sample.epub")
            try Data("zz".utf8).write(to: epub)

            let result = await importer.add(urls: [epub], autoClassifyEnabled: false, thickThreshold: 100)
            #expect(result.addedIDs.count == 1)
            #expect(result.coverFailures.isEmpty)
            #expect(try db.fetchAllBooks().count == 1)

            guard let id = result.addedIDs.first else {
                Issue.record("expected one added book id")
                return
            }
            let thumb = dir.appendingPathComponent("Thumbnails/\(id)/thumbnail.jpg")
            #expect(FileManager.default.fileExists(atPath: thumb.path))
            let written = try Data(contentsOf: thumb)
            #expect(written == coverBytes)
        }
    }
}
