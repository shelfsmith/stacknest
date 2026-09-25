// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// PR #4: `Database.bookIDs(forPaths:)`。
///
/// シェルフを表示中に Finder からドロップしたファイルのうち、**既にライブラリにあるもの**
/// （`ImportResult.alreadyPresent` = URL だけ）もシェルフへ入れるために、パスから本の ID を引く。
@Suite("Database.bookIDs(forPaths:)（登録済みの本をシェルフへ・PR #4）")
struct BookIDsForPathsTests {
    private func makeBook(id: Int, path: String?) -> BookRow {
        BookRow(
            id: id, title: "B\(id)", author: nil, genre: nil,
            path: path, dateAdded: Date(timeIntervalSince1970: Double(id)), playDate: nil,
            bookType: 0, fileType: 2, pages: nil, rating: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil)
    }

    private func makeDB(_ books: [BookRow]) throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        for b in books { try db.insertBook(b) }
        return db
    }

    @Test("一致したパスの本の ID を、渡したパスの順に返す")
    func returnsIDsInPathOrder() throws {
        let db = try makeDB([
            makeBook(id: 1, path: "/a/1.zip"),
            makeBook(id: 2, path: "/a/2.zip"),
            makeBook(id: 3, path: "/b/3.zip"),
        ])

        #expect(try db.bookIDs(forPaths: ["/b/3.zip", "/a/1.zip"]) == [3, 1])
    }

    @Test("一致しないパスは無視する")
    func ignoresUnknownPaths() throws {
        let db = try makeDB([makeBook(id: 1, path: "/a/1.zip")])

        #expect(try db.bookIDs(forPaths: ["/x/none.zip", "/a/1.zip"]) == [1])
        #expect(try db.bookIDs(forPaths: ["/x/none.zip"]).isEmpty)
    }

    @Test("空の入力では空を返す")
    func emptyInput() throws {
        let db = try makeDB([makeBook(id: 1, path: "/a/1.zip")])
        #expect(try db.bookIDs(forPaths: []).isEmpty)
    }

    /// 同じパスを指す本が複数あるなら、どれもドロップしたファイルの本なので全部返す。
    /// 同じパスを 2 回渡しても ID は重複させない。
    @Test("同じパスの本は全部返し、ID は重複させない")
    func duplicatePaths() throws {
        let db = try makeDB([
            makeBook(id: 1, path: "/a/same.zip"),
            makeBook(id: 2, path: "/a/same.zip"),
        ])

        #expect(try db.bookIDs(forPaths: ["/a/same.zip", "/a/same.zip"]) == [1, 2])
    }

    /// ★ フォルダを丸ごとドロップすると数千件になりうる。SQLite の変数の上限を超えないよう
    /// 分割して問い合わせるので、分割の境界をまたいでも取りこぼさないことを固定する。
    @Test("分割の境界をまたぐ件数でも全部返す")
    func chunkBoundary() throws {
        let n = Database.bookIDsForPathsChunkSize * 2 + 7
        let db = try makeDB((1...n).map { makeBook(id: $0, path: "/lib/\($0).zip") })

        let ids = try db.bookIDs(forPaths: (1...n).map { "/lib/\($0).zip" })
        #expect(ids == Array(1...n))
    }

    @Test("閉じた DB では空を返す")
    func closedDatabaseReturnsEmpty() throws {
        let db = try makeDB([makeBook(id: 1, path: "/a/1.zip")])
        db.close()
        #expect(try db.bookIDs(forPaths: ["/a/1.zip"]).isEmpty)
    }
}
