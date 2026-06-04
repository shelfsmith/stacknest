// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
@testable import StackroomFormat

@Suite("Database.distinctValues — multi-value")
struct DistinctValuesMultiValueTests {

    private func makeDBWithGenres(_ genres: [String?]) throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv_mv_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: dbURL, mode: .createOrReplace)
        try db.migrate()
        for (i, g) in genres.enumerated() {
            let rec = BookRecord(
                id: 0,
                title: "T\(i)",
                author: nil,
                genre: g,
                path: "/x\(i).zip",
                dateAdded: Date(),
                playDate: nil,
                bookType: 0,
                fileType: 2,
                pages: 0,
                myRate: 0,
                unseen: false,
                keywordA: nil, keywordB: nil, keywordC: nil,
                neta: nil
            )
            _ = try db.insertBookReturningID(rec)
        }
        return db
    }

    @Test
    func singleValuesAreUnchanged() throws {
        let db = try makeDBWithGenres(["マンガ", "小説", "画集"])
        let values = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .library)
        #expect(Set(values) == Set(["マンガ", "小説", "画集"]))
    }

    @Test
    func commaSeparatedValuesAreSplit() throws {
        let db = try makeDBWithGenres(["マンガ, 小説", "画集"])
        let values = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .library)
        #expect(Set(values) == Set(["マンガ", "小説", "画集"]))
    }

    @Test
    func uniqueAcrossRows() throws {
        let db = try makeDBWithGenres(["マンガ", "マンガ, 小説", "小説, 画集"])
        let values = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .library)
        #expect(Set(values) == Set(["マンガ", "小説", "画集"]))
    }

    @Test
    func emptyStringExcluded() throws {
        let db = try makeDBWithGenres(["マンガ", nil])
        let values = try db.distinctValues(forColumn: "genre", query: "", sidebarScope: .library)
        #expect(values == ["マンガ"])
    }

    @Test
    func integerColumnNotSplit() throws {
        let db = try makeDBWithGenres(["x"])
        let values = try db.distinctValues(forColumn: "book_type", query: "", sidebarScope: .library)
        #expect(values == ["0"])
    }
}
