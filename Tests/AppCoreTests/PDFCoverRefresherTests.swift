// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppKit
import PDFKit
@testable import AppCore

/// G54-S4 修正ラウンド2: `CoverRefresher.extractCoverData` の PDF 分岐が `preferredName` を
/// 一切見ずに常に 1 ページ目を返していた欠陥の回帰網。EPUB 側の
/// `EPUBReaderGlobalTests.preferredEntryIsRespected` と対称になる形にしてある。
///
/// 期待値は「PDF 化する前の色」ではなく、**`CoverRefresher` と同じ `PDFBookContent.pageImageData`
/// を直接呼んで得た、そのページ自身のレンダリング結果**にする。`PDFBookContent` の手組み
/// CGContext 描画は `PDFCoverExtractor`（`page.thumbnail(of:for:)` 経由）と色変換の経路が異なり、
/// PDF 化前のスウォッチ画素を ground truth にすると色空間変換のずれが `PDFCoverExtractorTests` の
/// 許容誤差では吸収しきれない（実測: 緑ページで R/B が 100 以上ずれた）。同一パイプラインの
/// 出力同士を比べれば、この問題を避けつつ「選んだページの中身が本当に返っているか」を確かめられる。
@Suite("G54-S4: PDF の preferredName が表紙に反映される")
struct PDFCoverRefresherTests {
    /// ページごとに塗りつぶし色を変えた PDF をその場で作る（`Tests/ArchiveAdapterTests/PDFCoverExtractorTests.swift`
    /// の `makePDF(pages:colors:)` に倣う。テストターゲットが異なるため直接の共有はできない）。
    private func makePDF(colors: [NSColor]) throws -> URL {
        let doc = PDFDocument()
        for (i, color) in colors.enumerated() {
            let img = NSImage(size: NSSize(width: 32, height: 32))
            img.lockFocus()
            color.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
            img.unlockFocus()
            guard let page = PDFPage(image: img) else {
                Issue.record("PDFPage(image:) failed to build test fixture page")
                continue
            }
            doc.insert(page, at: i)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g54s4-refresher-\(UUID().uuidString).pdf")
        #expect(doc.write(to: url))
        return url
    }

    /// `CoverRefresher` の PDF 分岐と全く同じ呼び出し（`PDFBookContent.pageImageData(at:maxPixelSize:)`,
    /// maxPixelSize 1200）で、指定ページ (0-based) の期待画像を直接作る。
    private func expectedPageData(url: URL, pageIndex: Int) throws -> Data {
        let content = try #require(PDFBookContent(url: url))
        return try #require(content.pageImageData(at: pageIndex, maxPixelSize: 1200))
    }

    @Test("preferredName で選んだページの画像が返る（1 ページ目固定に落ちない）")
    func preferredEntryIsRespected() async throws {
        let url = try makePDF(colors: [.red, .green, .blue])
        defer { try? FileManager.default.removeItem(at: url) }

        // PDFCoverExtractor は 1 始まりのページ番号を候補名にするので "2" = 2 ページ目（緑、0-based index 1）。
        let data = try await CoverRefresher.extractCoverData(sourceURL: url, preferredName: "2")
        let expectedPage2 = try expectedPageData(url: url, pageIndex: 1)
        let expectedPage1 = try expectedPageData(url: url, pageIndex: 0)
        #expect(data == expectedPage2, "expected page 2's own rendering, got something else")
        #expect(data != expectedPage1, "page 2 should not look like page 1 (would mean preferredName was ignored)")
    }

    @Test("preferredName が無い・範囲外・数でないときは 1 ページ目に落ちる", arguments: [nil, "0", "99", "abc", ""])
    func fallsBackToFirstPage(name: String?) async throws {
        let url = try makePDF(colors: [.red, .green, .blue])
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try await CoverRefresher.extractCoverData(sourceURL: url, preferredName: name)
        let expectedPage1 = try expectedPageData(url: url, pageIndex: 0)
        #expect(data == expectedPage1)
    }

    @Test("@ 始まりの preferredName（動画の場面指定の印）はページ番号として扱わず 1 ページ目に落ちる")
    func atPrefixedNameIsIgnored() async throws {
        let url = try makePDF(colors: [.red, .green, .blue])
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try await CoverRefresher.extractCoverData(sourceURL: url, preferredName: "@t=1.0")
        let expectedPage1 = try expectedPageData(url: url, pageIndex: 0)
        #expect(data == expectedPage1)
    }
}
