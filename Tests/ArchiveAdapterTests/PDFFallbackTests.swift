// SPDX-License-Identifier: MIT
//
// Phase 2.5i PDF fallback tests.
//
// Note: ArchiveAdapter doesn't choose between image vs PDF — image-first-hit,
// then PDF fallback preference lives in BookAddCoordinator (C5). These tests
// only verify that `extractFirstPDFData(in:)` returns the first PDF when one
// exists and nil otherwise. Zip-internal PDF coverage is exercised by C10 smoke.
import Testing
import Foundation
@testable import ArchiveAdapter

@Suite("PDF fallback extraction")
struct PDFFallbackTests {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-fallback-\(UUID())")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func folderWithPDFReturnsFirstPDF() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdfURL = dir.appendingPathComponent("a.pdf")
        let dummy: Data = "%PDF-1.4\n%EOF".data(using: .utf8)!
        try dummy.write(to: pdfURL)

        let extractor = FolderCoverExtractor()
        let data = try await extractor.extractFirstPDFData(in: dir)
        #expect(data != nil)
    }

    @Test func folderWithoutPDFReturnsNil() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let imageURL = dir.appendingPathComponent("a.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: imageURL)

        let extractor = FolderCoverExtractor()
        let data = try await extractor.extractFirstPDFData(in: dir)
        #expect(data == nil)
    }
}
