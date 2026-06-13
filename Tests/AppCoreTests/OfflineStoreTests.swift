// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import LibraryServerAPI

@Suite("OfflineStore")
struct OfflineStoreTests {
    private func detail(_ id: Int, _ title: String) -> BookDetailDTO {
        BookDetailDTO(id: id, title: title, author: nil, genre: nil, path: nil,
            dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 2,
            pages: nil, rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil,
            neta: nil, memo: nil, series: nil, volume: nil, coverImageName: nil,
            coverCropRectJSON: nil, pageDirection: nil)
    }
    private func tmpStore() -> OfflineStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ofl-\(UUID().uuidString)")
        return OfflineStore(baseDirectory: dir)
    }
    @Test func saveListFileURLRemove() throws {
        let store = tmpStore()
        let sid = UUID()
        try store.save(detail(7, "Book"), serverID: sid, libraryUUID: "u", libraryName: "Lib",
                       fileExtension: "zip", fileData: Data([1,2,3]), coverData: Data([9]))
        let all = store.all()
        #expect(all.count == 1)
        #expect(all.first?.bookID == 7)
        #expect(all.first?.libraryName == "Lib")
        #expect(all.first?.hasCachedCover == true)
        let url = store.fileURL(for: all.first!)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == Data([1,2,3]))
        #expect(store.totalSizeBytes() >= 3)
        store.remove(serverID: sid, libraryUUID: "u", bookID: 7)
        #expect(store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func updateLastPagePersists() throws {
        let store = tmpStore()
        let sid = UUID()
        try store.save(detail(1, "B"), serverID: sid, libraryUUID: "u", libraryName: "L",
                       fileExtension: "zip", fileData: Data([0]), coverData: nil)
        store.updateLastPage(serverID: sid, libraryUUID: "u", bookID: 1, page: 5)
        #expect(OfflineStore(baseDirectory: store.baseDirectory).all().first?.lastPage == 5)
    }
    @Test func isDownloadedReflectsState() throws {
        let store = tmpStore()
        let sid = UUID()
        #expect(store.isDownloaded(serverID: sid, libraryUUID: "u", bookID: 1) == false)
        try store.save(detail(1, "B"), serverID: sid, libraryUUID: "u", libraryName: "L",
                       fileExtension: "zip", fileData: Data([0]), coverData: nil)
        #expect(store.isDownloaded(serverID: sid, libraryUUID: "u", bookID: 1) == true)
    }
}
