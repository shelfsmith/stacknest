// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
import StackroomFormat

// A minimal parser stub that mimics FilenameParser.parse for test purposes.
// LibraryStore cannot import AppCore (would create a circular dependency),
// so the real parser is injected as a closure at call site.
private func stubbedParser(title: String, filename: String?) -> (series: String?, volume: Double?) {
    // Simple heuristic: "ワンピース 第5巻" → series="ワンピース", volume=5
    if title.contains("第") && title.contains("巻") {
        if let range = title.range(of: "第"),
           let volRange = title.range(of: "巻"),
           let num = Double(title[range.upperBound..<volRange.lowerBound]) {
            let seriesEnd = title.index(before: range.lowerBound)
            let series = title[title.startIndex...seriesEnd]
                .trimmingCharacters(in: .whitespaces)
            return (series.isEmpty ? nil : series, num)
        }
    }
    return (nil, nil)
}

@Suite("LibraryImporter fills series/volume from title")
struct ImportFillsSeriesVolumeTests {
    private func makeDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    @Test
    func importFillsSeriesVolumeFromTitleWhenXMLValuesAreNil() throws {
        let db = try makeDB()
        defer { db.close() }

        // XML-equivalent BookRecord (series/volume = nil, as from Stackroom XML)
        let xmlRecord = BookRecord(
            id: 1,
            title: "ワンピース 第5巻",
            dateAdded: Date(timeIntervalSince1970: 0)
            // series and volume default to nil
        )

        let importer = LibraryImporter(database: db, seriesVolumeParser: stubbedParser)
        let document = LibraryDocument(books: ["1": xmlRecord], anomalies: [])
        let summary = try importer.run(document: document)

        #expect(summary.imported == 1)

        let inserted = try db.fetchAllBooks().first
        #expect(inserted?.title == "ワンピース 第5巻")   // title is unchanged
        #expect(inserted?.series == "ワンピース")
        #expect(inserted?.volume == 5.0)
    }

    @Test
    func importPreservesXMLProvidedSeriesAndVolume() throws {
        let db = try makeDB()
        defer { db.close() }

        // When XML provides series/volume, they must take priority
        let xmlRecord = BookRecord(
            id: 1,
            title: "ワンピース 第5巻",
            dateAdded: Date(timeIntervalSince1970: 0),
            series: "ONE PIECE",   // XML-supplied value
            volume: 99.0           // XML-supplied value
        )

        let importer = LibraryImporter(database: db, seriesVolumeParser: stubbedParser)
        let document = LibraryDocument(books: ["1": xmlRecord], anomalies: [])
        _ = try importer.run(document: document)

        let inserted = try db.fetchAllBooks().first
        #expect(inserted?.series == "ONE PIECE")   // XML value preserved
        #expect(inserted?.volume == 99.0)          // XML value preserved
    }

    @Test
    func importWithoutParserSkipsSeriesVolumeFill() throws {
        let db = try makeDB()
        defer { db.close() }

        // Default importer (no parser) should behave as before — no parser injected
        let xmlRecord = BookRecord(
            id: 1,
            title: "ワンピース 第5巻",
            dateAdded: Date(timeIntervalSince1970: 0)
        )

        let importer = LibraryImporter(database: db)   // no parser
        let document = LibraryDocument(books: ["1": xmlRecord], anomalies: [])
        _ = try importer.run(document: document)

        let inserted = try db.fetchAllBooks().first
        #expect(inserted?.series == nil)
        #expect(inserted?.volume == nil)
    }
}
