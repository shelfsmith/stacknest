// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// G35a-1 Task A1: `Database.allBookPaths()`。
///
/// `FolderWatcher.scanAll()` は「既にライブラリにあるパスの集合」しか要らないのに
/// `fetchAllBooks()` で**全 24 カラム × 全行をデコード**していた（10,752 冊 + 12,180 冊）。
/// それが `@MainActor` 上で 60 秒ごとに走っていたのが G35 の対象。
///
/// ここでは「必要なものだけ返す」ことと、`fetchAllBooks()` と**同じ母集合**を見ていることを固定する。
@Suite("Database.allBookPaths（監視フォルダ走査用・G35a-1）")
struct AllBookPathsTests {
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

    @Test("登録済みの全パスを返す")
    func returnsEveryPath() throws {
        let db = try makeDB([
            makeBook(id: 1, path: "/a/1.zip"),
            makeBook(id: 2, path: "/a/2.zip"),
            makeBook(id: 3, path: "/b/3.zip"),
        ])

        #expect(try db.allBookPaths() == ["/a/1.zip", "/a/2.zip", "/b/3.zip"])
    }

    /// ★ `path` が nil の本（フォルダ本の一部・取り込み途中等）を含めると、
    /// 監視フォルダ側の「既存かどうか」の判定が壊れる。
    @Test("path が nil の本は含まれない")
    func skipsNilPaths() throws {
        let db = try makeDB([
            makeBook(id: 1, path: "/a/1.zip"),
            makeBook(id: 2, path: nil),
            makeBook(id: 3, path: "/b/3.zip"),
        ])

        let paths = try db.allBookPaths()
        #expect(paths == ["/a/1.zip", "/b/3.zip"])
        #expect(paths.count == 2)
    }

    /// 同じパスを指す本が複数あっても、用途（存在判定）では 1 件でよい。
    /// Set を返す意味論をここで固定する。
    @Test("同じパスが重複していても集合として 1 件")
    func deduplicates() throws {
        let db = try makeDB([
            makeBook(id: 1, path: "/a/same.zip"),
            makeBook(id: 2, path: "/a/same.zip"),
        ])

        #expect(try db.allBookPaths() == ["/a/same.zip"])
    }

    @Test("空のライブラリでは空集合")
    func emptyLibrary() throws {
        let db = try makeDB([])
        #expect(try db.allBookPaths().isEmpty)
    }

    /// ★ `fetchAllBooks()` の置き換えなので、**同じ母集合**を見ていなければならない。
    /// 片方だけが拾う本があると、監視フォルダが既存の本を再取り込みする（またはしない）事故になる。
    @Test("fetchAllBooks と同じ母集合を見ている")
    func agreesWithFetchAllBooks() throws {
        let db = try makeDB([
            makeBook(id: 1, path: "/a/1.zip"),
            makeBook(id: 2, path: nil),
            makeBook(id: 3, path: "/b/3.zip"),
            makeBook(id: 4, path: "/b/3.zip"),
        ])

        let viaFetchAll = Set(try db.fetchAllBooks().compactMap { $0.path })
        #expect(try db.allBookPaths() == viaFetchAll)
    }

    /// 閉じたライブラリでは空を返す（`fetchAllBooks` と同じ扱い）。
    @Test("閉じた DB では空集合を返す")
    func closedDatabaseReturnsEmpty() throws {
        let db = try makeDB([makeBook(id: 1, path: "/a/1.zip")])
        db.close()
        #expect(try db.allBookPaths().isEmpty)
    }
}
