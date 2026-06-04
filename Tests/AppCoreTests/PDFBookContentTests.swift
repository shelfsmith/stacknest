// SPDX-License-Identifier: MIT
import Testing
import Foundation
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
