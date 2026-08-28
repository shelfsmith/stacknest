// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("改名のための取り出し")
struct RenameQueriesTests {
    /// 既存の LibraryStoreTests と同じ作法（`AllBookPathsTests` を参照）。
    private func makeDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    private func book(_ id: Int, path: String, series: String? = nil,
                      volume: Double? = nil) -> BookRow {
        BookRow(id: id, title: "B\(id)", author: nil, genre: nil, path: path,
                dateAdded: Date(timeIntervalSince1970: Double(id)), playDate: nil,
                bookType: 0, fileType: 2, pages: nil, rating: 0, unseen: true,
                keywordA: nil, keywordB: nil, keywordC: nil, neta: nil,
                series: series, volume: volume)
    }

    @Test("ID を指定して本を取り出す（順序は指定順）")
    func rowsByIDs() throws {
        let db = try makeDB()
        try db.insertBook(book(1, path: "/x/a.zip"))
        try db.insertBook(book(2, path: "/x/b.zip"))
        try db.insertBook(book(3, path: "/x/c.zip"))

        let rows = try db.bookRows(ids: [2, 1])
        #expect(rows.map(\.id) == [2, 1])
        #expect(rows.map(\.title) == ["B2", "B1"])
    }

    @Test("居ない ID は黙って落ちる（結果に現れない）")
    func missingIDs() throws {
        let db = try makeDB()
        try db.insertBook(book(1, path: "/x/a.zip"))
        #expect(try db.bookRows(ids: [1, 99999]).map(\.id) == [1])
    }

    @Test("シリーズごとの最大巻を引く")
    func maxVolume() throws {
        let db = try makeDB()
        try db.insertBook(book(1, path: "/x/a.zip", series: "長い", volume: 120))
        try db.insertBook(book(2, path: "/x/b.zip", series: "長い", volume: 7))
        try db.insertBook(book(3, path: "/x/c.zip", series: "短い", volume: 3))

        let maxes = try db.maxVolumeBySeries(["長い", "短い", "居ない"])
        #expect(maxes["長い"] == 120)
        #expect(maxes["短い"] == 3)
        #expect(maxes["居ない"] == nil)
    }

    @Test("巻数を持たない本しか無いシリーズは返らない")
    func seriesWithoutVolume() throws {
        let db = try makeDB()
        try db.insertBook(book(1, path: "/x/a.zip", series: "巻なし", volume: nil))
        #expect(try db.maxVolumeBySeries(["巻なし"]).isEmpty)
    }

    @Test("空の指定では空を返す")
    func emptyInput() throws {
        let db = try makeDB()
        #expect(try db.bookRows(ids: []).isEmpty)
        #expect(try db.maxVolumeBySeries([]).isEmpty)
    }
}
