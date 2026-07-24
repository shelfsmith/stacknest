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
        let lib = UUID().uuidString
        try store.save(detail(7, "Book"), serverID: sid, libraryUUID: lib, libraryName: "Lib",
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
        store.remove(serverID: sid, libraryUUID: lib, bookID: 7)
        #expect(store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func updateLastPagePersists() throws {
        let store = tmpStore()
        let sid = UUID()
        let lib = UUID().uuidString
        try store.save(detail(1, "B"), serverID: sid, libraryUUID: lib, libraryName: "L",
                       fileExtension: "zip", fileData: Data([0]), coverData: nil)
        store.updateLastPage(serverID: sid, libraryUUID: lib, bookID: 1, page: 5)
        #expect(OfflineStore(baseDirectory: store.baseDirectory).all().first?.lastPage == 5)
    }
    @Test func isDownloadedReflectsState() throws {
        let store = tmpStore()
        let sid = UUID()
        let lib = UUID().uuidString
        #expect(store.isDownloaded(serverID: sid, libraryUUID: lib, bookID: 1) == false)
        try store.save(detail(1, "B"), serverID: sid, libraryUUID: lib, libraryName: "L",
                       fileExtension: "zip", fileData: Data([0]), coverData: nil)
        #expect(store.isDownloaded(serverID: sid, libraryUUID: lib, bookID: 1) == true)
    }

    @Test func saveRejectsNonUUIDLibraryUUIDAndWritesNothingOutsideBase() throws {
        let store = tmpStore()
        let sid = UUID()
        // 非 UUID かつパストラバーサルを狙った値。書き込みが起きないこと・base 外に何も
        // 作られないことを検証する。
        let malicious = "../../../../tmp/evil-\(UUID().uuidString)"
        #expect(throws: OfflineStoreError.invalidLibraryUUID) {
            try store.save(detail(1, "B"), serverID: sid, libraryUUID: malicious, libraryName: "L",
                           fileExtension: "zip", fileData: Data([0xDE, 0xAD]), coverData: nil)
        }
        #expect(store.all().isEmpty)
        // base directory 自体がまだ作られていない（createDirectory より前に弾かれる）はず。
        #expect(!FileManager.default.fileExists(atPath: store.baseDirectory.path))

        // 単に UUID 形式でないだけの値も同様に拒否される。
        #expect(throws: OfflineStoreError.invalidLibraryUUID) {
            try store.save(detail(1, "B"), serverID: sid, libraryUUID: "not-a-uuid", libraryName: "L",
                           fileExtension: "zip", fileData: Data([0]), coverData: nil)
        }
        #expect(store.all().isEmpty)
    }

    @Test func saveRejectsBadFileExtension() throws {
        let store = tmpStore()
        let sid = UUID()
        let lib = UUID().uuidString
        for bad in ["../evil", "a/b", "zip.", "..", "a b", "toolongextensionxx"] {
            #expect(throws: OfflineStoreError.invalidFileExtension) {
                try store.save(detail(1, "B"), serverID: sid, libraryUUID: lib, libraryName: "L",
                               fileExtension: bad, fileData: Data([0]), coverData: nil)
            }
        }
        #expect(store.all().isEmpty)
    }

    @Test func saveAcceptsValidUUIDAndNormalExtensions() throws {
        let store = tmpStore()
        let sid = UUID()
        for ext in ["zip", "cbz", "pdf", "jpg", "PNG"] {
            let lib = UUID().uuidString
            try store.save(detail(1, "B"), serverID: sid, libraryUUID: lib, libraryName: "L",
                           fileExtension: ext, fileData: Data([1]), coverData: nil)
            let book = store.all().first { $0.libraryUUID == lib }
            #expect(book?.relativeFilePath == "\(sid.uuidString)/\(lib)/1.\(ext)")
        }
    }

    @Test func adjacentConsecutiveOnlyStopsOnGap() throws {
        let store = tmpStore()
        let sid = UUID()
        let lib = UUID().uuidString

        // Helper to make a detail with series/volume
        func detailSV(_ id: Int, _ title: String, series: String, volume: Double) -> BookDetailDTO {
            BookDetailDTO(id: id, title: title, author: nil, genre: nil, path: nil,
                dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 2,
                pages: nil, rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil,
                neta: nil, memo: nil, series: series, volume: volume, coverImageName: nil,
                coverCropRectJSON: nil, pageDirection: nil)
        }

        // Download volumes 1, 2, and 5 of series "S" in the same server/library
        try store.save(detailSV(1, "S vol1", series: "S", volume: 1), serverID: sid, libraryUUID: lib,
                       libraryName: "L", fileExtension: "zip", fileData: Data([1]), coverData: nil)
        try store.save(detailSV(2, "S vol2", series: "S", volume: 2), serverID: sid, libraryUUID: lib,
                       libraryName: "L", fileExtension: "zip", fileData: Data([2]), coverData: nil)
        try store.save(detailSV(5, "S vol5", series: "S", volume: 5), serverID: sid, libraryUUID: lib,
                       libraryName: "L", fileExtension: "zip", fileData: Data([5]), coverData: nil)

        // from vol2, next -> nil (vol3 not downloaded; must NOT skip to vol5)
        let fromVol2Next = store.adjacentDownloaded(serverID: sid, libraryUUID: lib, series: "S", volume: 2, direction: .next)
        #expect(fromVol2Next == nil)

        // from vol1, next -> vol2
        let fromVol1Next = store.adjacentDownloaded(serverID: sid, libraryUUID: lib, series: "S", volume: 1, direction: .next)
        #expect(fromVol1Next?.detail.volume == 2)

        // from vol2, prev -> vol1
        let fromVol2Prev = store.adjacentDownloaded(serverID: sid, libraryUUID: lib, series: "S", volume: 2, direction: .prev)
        #expect(fromVol2Prev?.detail.volume == 1)

        // from vol5, prev -> nil (vol4 not downloaded)
        let fromVol5Prev = store.adjacentDownloaded(serverID: sid, libraryUUID: lib, series: "S", volume: 5, direction: .prev)
        #expect(fromVol5Prev == nil)

        // library isolation: different libraryUUID with vol1 -> next -> nil (vol2 not downloaded there)
        let otherLib = UUID().uuidString
        try store.save(detailSV(1, "S vol1 other", series: "S", volume: 1), serverID: sid, libraryUUID: otherLib,
                       libraryName: "L2", fileExtension: "zip", fileData: Data([10]), coverData: nil)
        let fromOtherLibNext = store.adjacentDownloaded(serverID: sid, libraryUUID: otherLib, series: "S", volume: 1, direction: .next)
        #expect(fromOtherLibNext == nil)
    }

    @Test func removeBooksDeletesAllGiven() throws {
        let store = tmpStore()
        let sid = UUID()
        let lib = UUID().uuidString
        // Save 3 books in the same server/library with different IDs
        try store.save(detail(10, "Book A"), serverID: sid, libraryUUID: lib, libraryName: "Lib",
                       fileExtension: "zip", fileData: Data([1]), coverData: nil)
        try store.save(detail(20, "Book B"), serverID: sid, libraryUUID: lib, libraryName: "Lib",
                       fileExtension: "zip", fileData: Data([2]), coverData: nil)
        try store.save(detail(30, "Book C"), serverID: sid, libraryUUID: lib, libraryName: "Lib",
                       fileExtension: "zip", fileData: Data([3]), coverData: nil)
        let books = store.all()
        #expect(books.count == 3)
        // Remove first 2, leaving only the third
        store.removeBooks(Array(books.prefix(2)))
        let remaining = store.all()
        #expect(remaining.count == 1)
        // The remaining book should be the one not in the first two
        let removedIDs = Set(books.prefix(2).map { $0.bookID })
        #expect(!removedIDs.contains(remaining[0].bookID))
    }
}
