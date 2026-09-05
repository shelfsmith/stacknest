// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import LibraryServerAPI

@Suite("G48-3: DownloadedBook.epubLocator")
struct OfflineStoreEPUBLocatorTests {
    private func detail(_ id: Int, _ title: String) -> BookDetailDTO {
        BookDetailDTO(id: id, title: title, author: nil, genre: nil, path: nil,
            dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 2,
            pages: nil, rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil,
            neta: nil, memo: nil, series: nil, volume: nil, coverImageName: nil,
            coverCropRectJSON: nil, pageDirection: nil)
    }
    private func tmpStore() -> OfflineStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ofl-epub-\(UUID().uuidString)")
        return OfflineStore(baseDirectory: dir)
    }
    private func book(_ id: Int) -> DownloadedBook {
        DownloadedBook(detail: detail(id, "t"), serverID: UUID(), libraryUUID: UUID().uuidString,
                       libraryName: "n", relativeFilePath: "\(id).epub", hasCachedCover: false,
                       downloadedAt: Date(), lastPage: nil)
    }

    @Test("旧 JSON（キー無し）を読める・往復する")
    func codableRoundTrip() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let b = book(1)
        let data = try enc.encode(b)
        #expect(!String(decoding: data, as: UTF8.self).contains("epubLocator"))
        #expect(try dec.decode(DownloadedBook.self, from: data).epubLocator == nil)
        var b2 = b
        b2.epubLocator = EPUBLocatorDTO(spine: 2, progress: 0.5, cfi: "c", engine: "washi")
        #expect(try dec.decode(DownloadedBook.self, from: try enc.encode(b2)).epubLocator?.spine == 2)
    }

    @Test("updateEPUBLocator が永続化される")
    func updatePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("offline-\(UUID().uuidString)")
        let store = OfflineStore(baseDirectory: dir)
        let sid = UUID()
        let lib = UUID().uuidString
        try store.save(detail(3, "Book"), serverID: sid, libraryUUID: lib, libraryName: "Lib",
                       fileExtension: "epub", fileData: Data("x".utf8), coverData: nil)
        store.updateEPUBLocator(serverID: sid, libraryUUID: lib, bookID: 3,
                                 locator: EPUBLocatorDTO(spine: 1, progress: 0.75))
        let reopened = OfflineStore(baseDirectory: dir)
        #expect(reopened.all().first { $0.bookID == 3 }?.epubLocator?.progress == 0.75)
    }
}
