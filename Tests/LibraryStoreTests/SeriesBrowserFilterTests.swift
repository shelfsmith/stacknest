// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
import StackroomFormat

@Suite("Series browser filter")
struct SeriesBrowserFilterTests {
    private func makeDB() throws -> (Database, URL) {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("series-fil-\(UUID()).sqlite")
        let db = try Database.openFile(at: tmpURL, mode: .createOrReplace)
        try db.migrate()
        return (db, tmpURL)
    }

    @Test
    func fetchDistinctSeriesValues() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "A", dateAdded: Date(), series: "ワンピース"))
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "B", dateAdded: Date(), series: "ワンピース"))
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "C", dateAdded: Date(), series: "ナルト"))
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "D", dateAdded: Date()))

        let values = try db.fetchDistinctSeriesValues()
        // NULL と空文字は除外、Series 値だけ
        #expect(values.sorted() == ["ナルト", "ワンピース"])
    }

    @Test
    func fetchDistinctSeriesExcludesEmptyString() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "A", dateAdded: Date(), series: ""))
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "B", dateAdded: Date(), series: "名探偵コナン"))

        let values = try db.fetchDistinctSeriesValues()
        #expect(values == ["名探偵コナン"])
    }

    @Test
    func seriesBrowserConstraintFiltersBooks() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "OP-1", dateAdded: Date(), series: "ワンピース"))
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "OP-2", dateAdded: Date(), series: "ワンピース"))
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "NA-1", dateAdded: Date(), series: "ナルト"))

        // series constraint で絞り込み
        let results = try db.searchBooks(
            query: "",
            sidebarScope: .library,
            browserConstraints: [("series", "ワンピース")]
        )
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.series == "ワンピース" })
    }

    @Test
    func distinctValuesForSeriesColumnReturnsExpected() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "X", dateAdded: Date(), series: "ドラゴンボール"))
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "Y", dateAdded: Date(), series: "ドラゴンボール"))
        _ = try db.insertBookReturningID(BookRecord(id: 0, title: "Z", dateAdded: Date(), series: "進撃の巨人"))

        let values = try db.distinctValues(
            forColumn: "series",
            query: "",
            sidebarScope: .library
        )
        #expect(values.sorted() == ["ドラゴンボール", "進撃の巨人"])
    }
}
