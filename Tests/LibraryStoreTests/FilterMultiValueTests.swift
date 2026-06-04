// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
@testable import StackroomFormat

@Suite("Database filter — multi-value")
struct FilterMultiValueTests {
    private func makeDBWithGenres(_ genres: [String]) throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmv_\(UUID().uuidString)")
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
    func exactMatch() throws {
        let db = try makeDBWithGenres(["マンガ", "小説"])
        var filter = FilterState()
        filter.genres = ["マンガ"]
        let rows = try db.searchBooks(query: "", sidebarScope: .library, filter: filter)
        #expect(rows.count == 1)
        #expect(rows.first?.genre == "マンガ")
    }

    @Test
    func multiValueLeadingMatch() throws {
        let db = try makeDBWithGenres(["マンガ, 小説", "画集"])
        var filter = FilterState()
        filter.genres = ["マンガ"]
        let rows = try db.searchBooks(query: "", sidebarScope: .library, filter: filter)
        #expect(rows.count == 1)
        #expect(rows.first?.genre == "マンガ, 小説")
    }

    @Test
    func multiValueMiddleMatch() throws {
        let db = try makeDBWithGenres(["小説, マンガ, 画集", "コミック"])
        var filter = FilterState()
        filter.genres = ["マンガ"]
        let rows = try db.searchBooks(query: "", sidebarScope: .library, filter: filter)
        #expect(rows.count == 1)
    }

    @Test
    func multiValueTrailingMatch() throws {
        let db = try makeDBWithGenres(["小説, マンガ", "画集"])
        var filter = FilterState()
        filter.genres = ["マンガ"]
        let rows = try db.searchBooks(query: "", sidebarScope: .library, filter: filter)
        #expect(rows.count == 1)
    }

    @Test
    func substringDoesNotMatchAdjacentText() throws {
        // "マンガ" filter で "マンガ風" "アニメ・マンガ" 等の境界外文字を含む値はヒットしない
        let db = try makeDBWithGenres(["マンガ風", "アニメ・マンガ", "コミック"])
        var filter = FilterState()
        filter.genres = ["マンガ"]
        let rows = try db.searchBooks(query: "", sidebarScope: .library, filter: filter)
        // "マンガ" 単独や "マンガ, ..." "..., マンガ" "..., マンガ, ..." のみマッチすべき
        // "マンガ風" "アニメ・マンガ" はマッチしない
        #expect(rows.count == 0)
    }
}
