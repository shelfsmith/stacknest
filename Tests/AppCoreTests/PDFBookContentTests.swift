// SPDX-License-Identifier: MIT
import Testing
import Foundation
import ImageIO
import CoreGraphics
@testable import AppCore

@Suite("PDFBookContent")
@MainActor
struct PDFBookContentTests {
    private func fixtureURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "PDFFixtures")
    }

    @Test func opensSinglePagePDF() throws {
        guard let url = fixtureURL("1page") else {
            Issue.record("fixture 1page.pdf missing"); return
        }
        let content = PDFBookContent(url: url)
        #expect(content != nil)
        #expect(content?.pageCount == 1)
    }

    @Test func opensMultiPagePDF() throws {
        guard let url = fixtureURL("5pages") else {
            Issue.record("fixture 5pages.pdf missing"); return
        }
        let content = PDFBookContent(url: url)
        #expect(content?.pageCount == 5)
    }

    @Test func coverJPEGNotNil() throws {
        guard let url = fixtureURL("1page") else {
            Issue.record("fixture 1page.pdf missing"); return
        }
        let content = PDFBookContent(url: url)
        let data = content?.coverJPEG(maxPixelSize: 1200)
        #expect(data != nil)
        #expect((data?.count ?? 0) > 100)
    }

    @Test func returnsNilForInvalidURL() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID()).pdf")
        #expect(PDFBookContent(url: url) == nil)
    }

    @Test func pageImageDataForEachPage() throws {
        guard let url = fixtureURL("5pages") else {
            Issue.record("fixture 5pages.pdf missing"); return
        }
        let content = PDFBookContent(url: url)
        #expect(content?.pageCount == 5)
        for p in 0..<5 {
            let data = content?.pageImageData(at: p, maxPixelSize: 600)
            #expect(data != nil, "page \(p) should render")
            #expect((data?.count ?? 0) > 100)
        }
    }

    @Test func pageImageDataOutOfRangeReturnsNil() throws {
        guard let url = fixtureURL("1page") else {
            Issue.record("fixture 1page.pdf missing"); return
        }
        let content = PDFBookContent(url: url)
        #expect(content?.pageImageData(at: 5, maxPixelSize: 600) == nil)
        #expect(content?.pageImageData(at: -1, maxPixelSize: 600) == nil)
    }
}

/// Phase 4.0: CG 置換後の保証 — MainActor 非依存・JPEG 妥当性・寸法規約。
@Suite("PDFBookContent (CG, off-main)")
struct PDFBookContentCGTests {
    private func fixtureURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "PDFFixtures")
    }

    /// 出力が JPEG (SOI マーカー FF D8) であり ImageIO でデコード可能、長辺 == maxPixelSize。
    @Test func outputIsDecodableJPEGWithRequestedLongEdge() throws {
        guard let url = fixtureURL("1page") else {
            Issue.record("fixture 1page.pdf missing"); return
        }
        let content = try #require(PDFBookContent(url: url))
        let data = try #require(content.pageImageData(at: 0, maxPixelSize: 800))
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(max(img.width, img.height) == 800)
        #expect(min(img.width, img.height) >= 1)
    }

    /// main thread 以外から呼んでも安全にレンダリングできる（4.1a サーバ前提の核心保証）。
    @Test func rendersOffMainThread() async throws {
        guard let url = fixtureURL("5pages") else {
            Issue.record("fixture 5pages.pdf missing"); return
        }
        let data: Data? = await Task.detached(priority: .userInitiated) {
            precondition(!Thread.isMainThread, "must run off main")
            guard let content = PDFBookContent(url: url) else { return nil }
            return content.pageImageData(at: 2, maxPixelSize: 600)
        }.value
        #expect((data?.count ?? 0) > 100)
        #expect(data?.prefix(2) == Data([0xFF, 0xD8]))
    }

    /// maxPixelSize=1 の境界（最小 1px 保証・クラッシュしない）。
    @Test func minimumPixelSizeDoesNotCrash() throws {
        guard let url = fixtureURL("1page") else {
            Issue.record("fixture 1page.pdf missing"); return
        }
        let content = try #require(PDFBookContent(url: url))
        let data = content.pageImageData(at: 0, maxPixelSize: 1)
        #expect(data != nil)
    }
}
