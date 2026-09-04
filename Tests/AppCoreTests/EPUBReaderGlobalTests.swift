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
        var direction: EPUBReadingDirection = .unknown
        var imageBook: (any EPUBImageBookReading)? = nil
        func open(url: URL) async throws -> EPUBBookInfo {
            EPUBBookInfo(title: "t", author: nil, language: nil, readingDirection: direction)
        }
        func coverImageData(url: URL, maxPixelSize: Int) async throws -> Data? { cover }
        func openImageBook(url: URL) async throws -> (any EPUBImageBookReading)? { imageBook }
    }

    final class FakeImageBook: EPUBImageBookReading, @unchecked Sendable {
        let pageCount: Int = 2
        let readingDirection: EPUBReadingDirection = .rtl
        let spreads: [EPUBPageSpread] = [.none, .none]
        func imageData(at index: Int) async throws -> Data { Data([UInt8(index)]) }
    }

    /// `EPUBImageBookContent(lazyURL:)` は初回アクセスまで `EPUBAdapter.reader` を見ないので、
    /// グローバルを差し替える必要がありこの親 suite に置く。
    @Suite("EPUBImageBookContent(lazyURL:)")
    struct LazyImageBookContent {
        private func tmpEPUB() throws -> URL {
            let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lz-\(UUID().uuidString).epub")
            try Data("zz".utf8).write(to: u)
            return u
        }

        @Test("openImageBook が nil を返すと BookContentError.unsupported(.text)")
        func nilHandleThrows() async throws {
            let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
            EPUBAdapter.reader = StubReader(cover: nil, imageBook: nil)
            let content = EPUBImageBookContent(lazyURL: try tmpEPUB())
            await #expect(throws: BookContentError.unsupported(.text)) {
                _ = try await content.pageCount
            }
        }

        @Test("未登録でも BookContentError.unsupported(.text)")
        func unregisteredThrows() async throws {
            let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
            EPUBAdapter.reader = nil
            let content = EPUBImageBookContent(lazyURL: try tmpEPUB())
            await #expect(throws: BookContentError.unsupported(.text)) {
                _ = try await content.pageCount
            }
        }

        @Test("handle が返れば通る")
        func handleSucceeds() async throws {
            let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
            EPUBAdapter.reader = StubReader(cover: nil, imageBook: FakeImageBook())
            let content = EPUBImageBookContent(lazyURL: try tmpEPUB())
            let count = try await content.pageCount
            #expect(count == 2)
        }

        /// `openImageBook` の呼び出し回数を数える（負のキャッシュ・同時アクセスの重複防止を確かめるため）。
        private final class CallCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() -> Int {
                lock.lock(); defer { lock.unlock() }
                value += 1
                return value
            }
            var count: Int {
                lock.lock(); defer { lock.unlock() }
                return value
            }
        }

        private struct CountingStubReader: EPUBReading {
            let counter: CallCounter
            let imageBook: (any EPUBImageBookReading)?
            func open(url: URL) async throws -> EPUBBookInfo {
                EPUBBookInfo(title: "t", author: nil, language: nil, readingDirection: .unknown)
            }
            func coverImageData(url: URL, maxPixelSize: Int) async throws -> Data? { nil }
            func openImageBook(url: URL) async throws -> (any EPUBImageBookReading)? {
                _ = counter.increment()
                return imageBook
            }
        }

        /// 最終レビュー Important #2: nil（画像本でない）は `.notImageBook` として記憶され、
        /// 2 回目以降はファイルに触れず（= reader を呼ばず）に throw する。
        @Test("nil handle は notImageBook として記憶され、2 回目は reader を呼び直さない")
        func nilHandleIsCachedAndNotRetried() async throws {
            let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
            let counter = CallCounter()
            EPUBAdapter.reader = CountingStubReader(counter: counter, imageBook: nil)
            let content = EPUBImageBookContent(lazyURL: try tmpEPUB())

            await #expect(throws: BookContentError.unsupported(.text)) {
                _ = try await content.pageCount
            }
            await #expect(throws: BookContentError.unsupported(.text)) {
                _ = try await content.pageCount
            }
            #expect(counter.count == 1)
        }

        /// 最終レビュー Important #2: 同時に複数箇所から初回アクセスしても `openImageBook` は 1 回だけ。
        @Test("4 並列の初回アクセスでも openImageBook は 1 回しか呼ばれない")
        func concurrentFirstAccessOpensOnce() async throws {
            let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
            let counter = CallCounter()
            EPUBAdapter.reader = CountingStubReader(counter: counter, imageBook: FakeImageBook())
            let content = EPUBImageBookContent(lazyURL: try tmpEPUB())

            async let a = content.pageCount
            async let b = content.pageCount
            async let c = content.pageCount
            async let d = content.pageCount
            let counts = try await [a, b, c, d]

            #expect(counts.allSatisfy { $0 == 2 })
            #expect(counter.count == 1)
        }
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

        @Test("EPUB の綴じ方向が取り込み時に pageDirection へ反映される")
        func importsPageDirection() async throws {
            let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
            EPUBAdapter.reader = StubReader(cover: nil, direction: .rtl)

            let (importer, db, dir) = try makeImporter()
            let epub = dir.appendingPathComponent("sample.epub")
            try Data("zz".utf8).write(to: epub)

            let result = await importer.add(urls: [epub], autoClassifyEnabled: false, thickThreshold: 100)
            guard let id = result.addedIDs.first else {
                Issue.record("expected one added book id")
                return
            }
            let book = try db.fetchAllBooks().first { $0.id == id }
            #expect(book?.pageDirection == .rightToLeft)
        }

        @Test("綴じ方向が不明なら pageDirection は書かれない")
        func unknownDirectionLeavesPageDirectionNil() async throws {
            let saved = EPUBAdapter.reader; defer { EPUBAdapter.reader = saved }
            EPUBAdapter.reader = StubReader(cover: nil, direction: .unknown)

            let (importer, db, dir) = try makeImporter()
            let epub = dir.appendingPathComponent("sample.epub")
            try Data("zz".utf8).write(to: epub)

            let result = await importer.add(urls: [epub], autoClassifyEnabled: false, thickThreshold: 100)
            guard let id = result.addedIDs.first else {
                Issue.record("expected one added book id")
                return
            }
            let book = try db.fetchAllBooks().first { $0.id == id }
            #expect(book?.pageDirection == nil)
        }
    }
}
