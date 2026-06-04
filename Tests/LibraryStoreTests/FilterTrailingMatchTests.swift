// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
@testable import StackroomFormat

@Suite("Filter trailing match for multi-value")
struct FilterTrailingMatchTests {
    private func makeDB(genres: [String]) throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftm_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        for (i, g) in genres.enumerated() {
            let rec = BookRecord(
                id: 0, title: "T\(i)", author: nil, genre: g,
                path: "/x\(i).zip", dateAdded: Date(), playDate: nil,
                bookType: 0, fileType: 2, pages: 0, myRate: 0, unseen: false,
                keywordA: nil, keywordB: nil, keywordC: nil, neta: nil
            )
            _ = try db.insertBookReturningID(rec)
        }
        return db
    }

    @Test
    func trailingValueMatches() throws {
        // "値2" 単体での filter — "値1, 値2" book がヒットすべき
        let db = try makeDB(genres: ["値1, 値2", "値3"])
        var filter = FilterState()
        filter.genres = ["値2"]
        let rows = try db.searchBooks(query: "", sidebarScope: .library, filter: filter)
        #expect(rows.count == 1)
        #expect(rows.first?.genre == "値1, 値2")
    }

    @Test
    func leadingValueMatches() throws {
        let db = try makeDB(genres: ["値1, 値2"])
        var filter = FilterState()
        filter.genres = ["値1"]
        let rows = try db.searchBooks(query: "", sidebarScope: .library, filter: filter)
        #expect(rows.count == 1)
    }

    @Test
    func singleValueExactMatch() throws {
        let db = try makeDB(genres: ["値2"])
        var filter = FilterState()
        filter.genres = ["値2"]
        let rows = try db.searchBooks(query: "", sidebarScope: .library, filter: filter)
        #expect(rows.count == 1)
    }

    // MARK: - browserConstraints 経路のマルチ値テスト

    @Test
    func browserConstraintTrailingMatch() throws {
        // distinctValues + browserConstraints の経路で「値2」(末尾) がヒット
        let db = try makeDB(genres: ["値1, 値2", "値3"])
        // Browser pane は distinctValues で chip を出し、選択値を browserConstraints として渡す
        let rows = try db.searchBooks(
            query: "",
            sidebarScope: .library,
            filter: FilterState(),
            browserConstraints: [("genre", "値2")]
        )
        #expect(rows.count == 1)
        #expect(rows.first?.genre == "値1, 値2")
    }

    @Test
    func browserConstraintLeadingMatch() throws {
        let db = try makeDB(genres: ["値1, 値2", "値3"])
        let rows = try db.searchBooks(
            query: "",
            sidebarScope: .library,
            filter: FilterState(),
            browserConstraints: [("genre", "値1")]
        )
        #expect(rows.count == 1)
    }

    @Test
    func browserConstraintMiddleMatch() throws {
        let db = try makeDB(genres: ["値0, 値1, 値2"])
        let rows = try db.searchBooks(
            query: "",
            sidebarScope: .library,
            filter: FilterState(),
            browserConstraints: [("genre", "値1")]
        )
        #expect(rows.count == 1)
    }
}
