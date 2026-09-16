// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

@Suite("ArchiveAdapter.coverExtractor(for:)")
struct ArchiveAdapterDispatchTests {

    @Test
    func zipReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.zip")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func cbzReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.cbz")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func cbrReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.cbr")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func folderReturnsFolderExtractor() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = ArchiveAdapter.coverExtractor(for: dir)
        #expect(ext is FolderCoverExtractor)
    }

    @Test
    func rarReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.rar")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func sevenZReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.7z")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func cb7ReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.cb7")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func unknownExtensionReturnsNil() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.xyz")
        #expect(ArchiveAdapter.coverExtractor(for: url) == nil)
    }

    // MARK: - G54-S4: EPUB は zip として扱う

    @Test
    func epubReturnsLibarchive() throws {
        // EPUB は zip なので、専用の抽出器を作らず既存の LibarchiveCoverExtractor を使い回す。
        let url = URL(fileURLWithPath: "/tmp/foo.epub")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func epubListsOnlyImages() async throws {
        // 画像 2 枚（1x1 PNG）と XHTML 1 枚を入れた zip を .epub の名前で作る。
        // listImageEntries が画像 2 件だけを返す（XHTML は混ざらない）ことを見る。
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g54s4-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let page01Data = try LibarchiveCoverExtractorTests.make1x1PNG(r: 10, g: 20, b: 30)
        let page02Data = try LibarchiveCoverExtractorTests.make1x1PNG(r: 40, g: 50, b: 60)
        let page01 = tmpDir.appendingPathComponent("page01.png")
        let page02 = tmpDir.appendingPathComponent("page02.png")
        try page01Data.write(to: page01)
        try page02Data.write(to: page02)

        let xhtml = tmpDir.appendingPathComponent("chapter1.xhtml")
        try "<html><body>hello</body></html>".write(to: xhtml, atomically: true, encoding: .utf8)

        let epubURL = tmpDir.appendingPathComponent("book.epub")
        // 既存の LibarchiveCoverExtractorTests.zipFiles（/usr/bin/zip 呼び出し）に倣う。
        try LibarchiveCoverExtractorTests.zipFiles([page01, page02, xhtml], to: epubURL, baseDir: tmpDir)

        let extractor = ArchiveAdapter.coverExtractor(for: epubURL)
        let listing = try await extractor?.listImageEntries(in: epubURL)

        #expect(listing?.names.count == 2)
        #expect(listing?.names.contains("page01.png") == true)
        #expect(listing?.names.contains("page02.png") == true)
        #expect(listing?.names.contains("chapter1.xhtml") == false)
    }
}
