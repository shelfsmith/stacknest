// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
import StackroomFormat
@testable import StackNest

/// PR #4: シェルフ（手動シェルフ・お気に入り）を表示中に Finder からファイルをドロップすると、
/// ライブラリには入るのにシェルフには入らなかった。
///
/// `LibraryBrowserView.handleAdd` は取り込み（`BookAddCoordinator.add`）の後に
/// `AppState.addImportedBooks(_:toShelf:)` を呼ぶ。入れる先のシェルフは**ドロップした時点で固定**して渡す
/// （取り込みは数十秒かかりうるので、その間にサイドバーの選択が変わっても、選び直した先に入れない）。
@Suite("ドロップで取り込んだ本をシェルフへ入れる（PR #4）")
@MainActor
struct ImportIntoShelfTests {

    private func record(id: Int, path: String) -> BookRecord {
        BookRecord(
            id: id, title: "B\(id)", author: nil, genre: nil,
            path: path, dateAdded: Date(timeIntervalSince1970: 100), playDate: nil,
            bookType: 0, fileType: 2, pages: 10, myRate: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil)
    }

    /// 3 冊入りの in-memory ライブラリと、空の手動シェルフを持つ `AppState`。
    private func makeState() throws -> (AppState, Database, Int64) {
        let db = try Database.openInMemory()
        try db.migrate()
        for id in 1...3 { try db.insertBook(record(id: id, path: "/lib/\(id).zip")) }
        let state = AppState(bundleURL: URL(fileURLWithPath: "/tmp/pr4-test.stacknest"))
        state.database = db
        state.favoritesShelfID = try db.ensureFavoritesShelf()
        let shelfID = try #require(state.createShelf(name: "S"))
        return (state, db, shelfID)
    }

    private func shelfBookIDs(_ db: Database, _ shelfID: Int64) throws -> [Int] {
        try db.fetchBooksInPlaylist(playlistID: shelfID).map(\.id)
    }

    @Test("新しく取り込んだ本がシェルフに入る")
    func addsNewlyImportedBooks() throws {
        let (state, db, shelfID) = try makeState()
        var result = BookImporter.ImportResult()
        result.addedIDs = [2, 3]

        #expect(state.addImportedBooks(result, toShelf: shelfID))
        #expect(try shelfBookIDs(db, shelfID) == [2, 3])
    }

    /// ★ 平木氏の判断（2026-09-26）: 既にライブラリにある本のファイルをドロップしたときも、
    /// シェルフに入れるつもりの操作なのでシェルフへ入れる。
    @Test("登録済みの本（alreadyPresent）もシェルフに入る")
    func addsAlreadyPresentBooks() throws {
        let (state, db, shelfID) = try makeState()
        var result = BookImporter.ImportResult()
        result.addedIDs = [3]
        result.alreadyPresent = [URL(fileURLWithPath: "/lib/1.zip")]

        #expect(state.addImportedBooks(result, toShelf: shelfID))
        #expect(try shelfBookIDs(db, shelfID) == [3, 1])
    }

    @Test("お気に入りにも入る")
    func addsToFavorites() throws {
        let (state, db, _) = try makeState()
        let favID = try #require(state.favoritesShelfID)
        var result = BookImporter.ImportResult()
        result.addedIDs = [2]

        #expect(state.addImportedBooks(result, toShelf: favID))
        #expect(try shelfBookIDs(db, favID) == [2])
    }

    /// ライブラリ・スマートシェルフ・最近の項目を表示中なら、`removableShelfID` は nil。
    @Test("シェルフが nil なら何もしない")
    func nilShelfIsNoOp() throws {
        let (state, db, shelfID) = try makeState()
        var result = BookImporter.ImportResult()
        result.addedIDs = [1]

        #expect(!state.addImportedBooks(result, toShelf: nil))
        #expect(try shelfBookIDs(db, shelfID).isEmpty)
    }

    /// ★ 取り込みの最中にそのシェルフを消していたら、行き場の無い行を作らない。
    @Test("取り込み中にシェルフが削除されていたら何もしない")
    func deletedShelfIsNoOp() throws {
        let (state, db, shelfID) = try makeState()
        state.deleteShelf(id: shelfID)
        var result = BookImporter.ImportResult()
        result.addedIDs = [1]

        #expect(!state.addImportedBooks(result, toShelf: shelfID))
        #expect(state.error == nil)
        let orphans = try db.fetchBooksInPlaylist(playlistID: shelfID)
        #expect(orphans.isEmpty)
    }

    /// ★ Codex レビュー（2026-09-26）: `addBooksToShelf` は失敗を内部で握るので、以前は書き込みに
    /// 失敗しても true を返し、「シェルフへの追加だけ行いました」と成功を告げていた。
    @Test("シェルフへの書き込みに失敗したら false を返し、エラーを出す")
    func shelfWriteFailureReturnsFalse() throws {
        let (state, db, shelfID) = try makeState()
        try db.write { conn in
            try conn.execute(sql: """
                CREATE TRIGGER block_shelf_insert BEFORE INSERT ON playlist_item
                BEGIN SELECT RAISE(ABORT, 'blocked'); END;
                """)
        }
        var result = BookImporter.ImportResult()
        result.alreadyPresent = [URL(fileURLWithPath: "/lib/1.zip")]

        #expect(!state.addImportedBooks(result, toShelf: shelfID))
        #expect(state.error != nil)
        #expect(try shelfBookIDs(db, shelfID).isEmpty)
    }

    @Test("入れる本が 1 冊も無ければ何もしない")
    func emptyResultIsNoOp() throws {
        let (state, db, shelfID) = try makeState()
        var result = BookImporter.ImportResult()
        result.alreadyPresent = [URL(fileURLWithPath: "/elsewhere/none.zip")]

        #expect(!state.addImportedBooks(result, toShelf: shelfID))
        #expect(try shelfBookIDs(db, shelfID).isEmpty)
    }
}
