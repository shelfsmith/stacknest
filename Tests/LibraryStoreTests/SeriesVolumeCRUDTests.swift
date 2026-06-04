// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
import StackroomFormat

@Suite("series/volume CRUD")
struct SeriesVolumeCRUDTests {
    private func makeDB() throws -> (Database, URL) {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("crud-\(UUID()).sqlite")
        let db = try Database.openFile(at: tmpURL, mode: .createOrReplace)
        try db.migrate()
        return (db, tmpURL)
    }

    @Test
    func insertAndFetchPreservesSeriesAndVolume() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = BookRecord(
            id: 0, title: "ワンピース 第5巻", dateAdded: Date(),
            series: "ワンピース", volume: 5.0
        )
        let id = try db.insertBookReturningID(rec)
        let fetched = try db.fetchAllBooks().first { $0.id == id }
        #expect(fetched?.series == "ワンピース")
        #expect(fetched?.volume == 5.0)
    }

    @Test
    func updateBookAppliesSeriesAndVolumePatch() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = BookRecord(id: 0, title: "Untitled", dateAdded: Date())
        let id = try db.insertBookReturningID(rec)
        try db.updateBook(id: id, patch: BookPatch(series: "ワンピース", volume: 5.5))
        let fetched = try db.fetchAllBooks().first { $0.id == id }
        #expect(fetched?.series == "ワンピース")
        #expect(fetched?.volume == 5.5)
    }

    @Test
    func zeroVolumeIsPreservedAsNonNull() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = BookRecord(
            id: 0, title: "進撃の巨人 0巻", dateAdded: Date(),
            series: "進撃の巨人", volume: 0.0
        )
        let id = try db.insertBookReturningID(rec)
        let fetched = try db.fetchAllBooks().first { $0.id == id }
        #expect(fetched?.volume == 0.0)  // NULL と 0.0 を取り違えないこと
        #expect(fetched?.volume != nil)
    }

    @Test
    func nilSeriesAndVolumeAreStoredAsNULL() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = BookRecord(id: 0, title: "Untitled", dateAdded: Date())
        let id = try db.insertBookReturningID(rec)
        let fetched = try db.fetchAllBooks().first { $0.id == id }
        #expect(fetched?.series == nil)
        #expect(fetched?.volume == nil)
    }

    @Test
    func clearVolumeSetsNULL() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = BookRecord(id: 0, title: "T", dateAdded: Date(), volume: 5.0)
        let id = try db.insertBookReturningID(rec)
        try db.updateBook(id: id, patch: BookPatch(clearVolume: true))
        let fetched = try db.fetchAllBooks().first { $0.id == id }
        #expect(fetched?.volume == nil)
    }

    @Test
    func clearSeriesSetsNULL() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = BookRecord(id: 0, title: "T", dateAdded: Date(), series: "S1")
        let id = try db.insertBookReturningID(rec)
        try db.updateBook(id: id, patch: BookPatch(clearSeries: true))
        let fetched = try db.fetchAllBooks().first { $0.id == id }
        #expect(fetched?.series == nil)
    }

    @Test
    func nilPatchDoesNotClearVolume() throws {
        // nil volume in patch = no-op (not a clear)
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = BookRecord(id: 0, title: "T", dateAdded: Date(), volume: 3.0)
        let id = try db.insertBookReturningID(rec)
        // patch with volume=nil should leave existing value unchanged
        try db.updateBook(id: id, patch: BookPatch(rating: 4))
        let fetched = try db.fetchAllBooks().first { $0.id == id }
        #expect(fetched?.volume == 3.0)  // unchanged
    }

    @Test
    func ftsTrigramSearchReturnsSeriesAndVolume() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let rec = BookRecord(
            id: 0, title: "ワンピース 第5巻", dateAdded: Date(),
            series: "ワンピース", volume: 5.0
        )
        _ = try db.insertBookReturningID(rec)

        // FTS trigram は 3 文字以上のクエリで発動
        let results = try db.searchBooks(query: "ワンピース", sidebarScope: .library)
        #expect(results.count == 1)
        #expect(results.first?.series == "ワンピース")
        #expect(results.first?.volume == 5.0)
    }
}
