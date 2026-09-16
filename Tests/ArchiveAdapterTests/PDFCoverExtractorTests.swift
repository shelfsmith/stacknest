// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import PDFKit
import Testing
@testable import ArchiveAdapter

@Suite("G54-S4: PDF の表紙候補")
struct PDFCoverExtractorTests {
    /// ページ数を指定して、その場で PDF を 1 つ作る。各ページは 32x32 の白紙画像。
    /// `PDFPage()` の空ページは `write(to:)` が成立しなかったため、`BookImporterTests.swift`
    /// の `threePagePDF()`（G54-S4 Task 1 以前から存在）に倣い `PDFPage(image:)` で作る。
    private func makePDF(pages: Int) throws -> URL {
        let doc = PDFDocument()
        for i in 0..<pages {
            let img = NSImage(size: NSSize(width: 32, height: 32))
            img.lockFocus()
            NSColor.white.drawSwatch(in: NSRect(x: 0, y: 0, width: 32, height: 32))
            img.unlockFocus()
            guard let page = PDFPage(image: img) else {
                Issue.record("PDFPage(image:) failed to build test fixture page")
                continue
            }
            doc.insert(page, at: i)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g54s4-\(UUID().uuidString).pdf")
        #expect(doc.write(to: url))
        return url
    }

    @Test("ページ数だけ候補が並び、名前はページ番号")
    func listsOnePerPage() async throws {
        let url = try makePDF(pages: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let listing = try await PDFCoverExtractor().listImageEntries(in: url)
        #expect(listing.names == ["1", "2", "3"])
        #expect(listing.truncated == false)
    }

    @Test("候補の数を数えられる")
    func countsPages() async throws {
        let url = try makePDF(pages: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let count = try await PDFCoverExtractor().countImageEntries(in: url)
        #expect(count.count == 5)
        #expect(count.truncated == false)
    }

    @Test("名前で指定したページが画像になる")
    func extractsNamedPage() async throws {
        let url = try makePDF(pages: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try await PDFCoverExtractor().extractCoverImage(from: url, preferredName: "2")
        #expect(!data.isEmpty)
        #expect(NSImage(data: data) != nil)
    }

    @Test("名前が無い・範囲外・数でないときは 1 ページ目に落ちる", arguments: [nil, "0", "99", "abc", ""])
    func fallsBackToFirstPage(name: String?) async throws {
        let url = try makePDF(pages: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try await PDFCoverExtractor().extractCoverImage(from: url, preferredName: name)
        #expect(!data.isEmpty)
    }

    @Test("名前なしの取り出しは 1 ページ目")
    func extractsFirstPageWithoutName() async throws {
        let url = try makePDF(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try await PDFCoverExtractor().extractCoverImage(from: url)
        #expect(!data.isEmpty)
    }

    @Test("開けない PDF は投げる")
    func throwsOnBrokenFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g54s4-broken-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) {
            _ = try await PDFCoverExtractor().listImageEntries(in: url)
        }
    }

    // `PDFDocument().write(to:)` は 0 ページの文書を渡しても素通しせず、Quartz が
    // 空文書を無効とみなして自動で白紙 1 ページ（Letter サイズ）を足してから書き出す
    // （実機確認: pageCount=0 → write → 再度開くと pageCount=1）。したがって
    // 「開けて pageCount==0」なフィクスチャは PDFKit 経由では作れない —
    // 手組みの `/Count 0` PDF も CoreGraphics が無効な文書として弾いて開けない
    // （実機確認: `PDFDocument(url:)` が nil を返す＝`throwsOnBrokenFile` と同じ経路）。
    // そのため「0 ページ要求」の実際の観測可能な挙動は「自動挿入された 1 ページを普通に扱う」
    // ことになる。実装側の `guard doc.pageCount > 0` は、この経路では踏めないが
    // 将来 PDFKit の挙動が変わった場合や他ツールが吐いた度外れな PDF に備えた防御として残す。
    @Test("0 ページを要求しても PDFKit が白紙 1 ページを自動で足すため、その 1 ページとして扱われる（落ちない）")
    func handlesEmptyDocument() async throws {
        let url = try makePDF(pages: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let listing = try await PDFCoverExtractor().listImageEntries(in: url)
        #expect(listing.names == ["1"])
        #expect(listing.truncated == false)
    }
}
