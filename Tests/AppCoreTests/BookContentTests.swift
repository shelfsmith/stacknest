// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryStore
@testable import AppCore

@Suite("BookContent")
@MainActor
struct BookContentTests {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AppCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func makeBook(id: Int, path: String) -> BookRow {
        BookRow(
            id: id, title: "t", author: nil, genre: nil, path: path,
            dateAdded: Date(timeIntervalSince1970: 0), playDate: nil,
            bookType: 0, fileType: 0, pages: nil, rating: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil
        )
    }

    @Test func archivePageCountAndOrder() async throws {
        let content = try BookContentFactory.make(for: makeBook(id: 1, path: fixture("three_pages.zip").path))
        let count = try await content.pageCount
        #expect(count == 3)
        let first = try await content.imageData(at: 0)
        #expect(first.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        let last = try await content.imageData(at: 2)
        #expect(last.count > 0)
    }

    @Test func archiveOutOfRangeThrows() async throws {
        let content = try BookContentFactory.make(for: makeBook(id: 1, path: fixture("three_pages.zip").path))
        await #expect(throws: (any Error).self) {
            _ = try await content.imageData(at: 99)
        }
    }

    @Test func folderPageCountAndOrder() async throws {
        let content = try BookContentFactory.make(for: makeBook(id: 2, path: fixture("folder_book").path))
        let count = try await content.pageCount
        #expect(count == 3)
        let first = try await content.imageData(at: 0)
        #expect(first.count > 0)
    }

    @Test func singleImageHasOnePage() async throws {
        let imgPath = fixture("folder_book").appendingPathComponent("page1.png").path
        let content = try BookContentFactory.make(for: makeBook(id: 3, path: imgPath))
        let count = try await content.pageCount
        #expect(count == 1)
        let data = try await content.imageData(at: 0)
        #expect(data.count > 0)
    }

    @Test func pdfPageCount() async throws {
        guard let pdf = Bundle.module.url(forResource: "5pages", withExtension: "pdf", subdirectory: "PDFFixtures") else {
            Issue.record("5pages.pdf fixture missing"); return
        }
        let content = try BookContentFactory.make(for: makeBook(id: 4, path: pdf.path))
        let count = try await content.pageCount
        #expect(count == 5)
        let p0 = try await content.imageData(at: 0)
        #expect(p0.count > 0)
    }

    @Test func videoThrowsUnsupported() {
        #expect(throws: BookContentError.self) {
            _ = try BookContentFactory.make(for: makeBook(id: 5, path: "/tmp/movie.mp4"))
        }
    }

    @Test func emptyPathThrows() {
        #expect(throws: BookContentError.self) {
            _ = try BookContentFactory.make(for: makeBook(id: 6, path: ""))
        }
    }
}
