// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import LibraryServerAPI

@Suite("OfflineBookContent")
struct OfflineBookContentTests {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AppCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    @Test func extensionDetectionByMagic() {
        #expect(offlineFileExtension(for: Data([0x50, 0x4B, 0x03, 0x04])) == "zip")
        #expect(offlineFileExtension(for: Data([0x25, 0x50, 0x44, 0x46])) == "pdf")
        #expect(offlineFileExtension(for: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
        #expect(offlineFileExtension(for: Data([0x89, 0x50, 0x4E, 0x47])) == "png")
        #expect(offlineFileExtension(for: Data([0,0,0,0])) == "zip")   // default
    }

    @Test func mapsToLocalBookRowAndOpens() async throws {
        let src = fixture("three_pages.zip")
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oflc-\(UUID().uuidString)")
        let store = OfflineStore(baseDirectory: dir)
        let sid = UUID()
        let detail = BookDetailDTO(id: 3, title: "T", author: nil, genre: nil, path: nil,
            dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 2, pages: nil,
            rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil,
            series: nil, volume: nil, coverImageName: nil, coverCropRectJSON: nil, pageDirection: "rtl")
        try store.save(detail, serverID: sid, libraryUUID: UUID().uuidString, libraryName: "L",
                       fileExtension: "zip", fileData: try Data(contentsOf: src), coverData: nil)
        let book = store.all().first!
        let fileURL = store.fileURL(for: book)
        let row = offlineBookRow(book, fileURL: fileURL)
        #expect(row.path == fileURL.path)
        #expect(row.pageDirection == .rightToLeft)
        let content = try BookContentFactory.make(for: row)
        let count = try await content.pageCount
        #expect(count >= 1)
    }
}
