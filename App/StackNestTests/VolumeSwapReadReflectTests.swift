// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
import StackroomFormat
@testable import StackNest

/// G34b: リーダー内で次巻へ移動したとき、既読マークと「読んだ日」が
/// **ブラウザを開き直さずに**一覧へ反映されることの回帰ガード。
///
/// ## 何が起きていたか
///
/// `AppState.resolveVolume` は巻送りで開く本に対し `db.markAsRead` だけを呼び、
/// `displayedBooks` を触っていなかった（当該行のコメントに「DB レベル更新に留め、背景ライブラリ
/// window の displayedBooks/選択を巻送りごとに揺らさない」と意図が明記されていた）。
/// 一方、最初に本を開く経路は `AppState.markAsRead(book:)` が
/// `refreshDisplayedBooks()` まで呼ぶため即反映する。
/// 結果として「最初に開いた本は反映、巻送りした本は反映されない」という非対称になっていた。
///
/// ## なぜ再取得ではなく行内更新なのか
///
/// `refreshDisplayedBooks()` を呼ぶと元コメントが避けた挙動が戻る:
/// 「読んだ日」降順で並べているとその本が先頭へジャンプし、「未読のみ」表示だと一覧から消える。
/// **並び順・要素数を動かさないこと自体が要件**なので、テストでも明示的に固定する。
@Suite("巻送りの既読反映（G34b）")
@MainActor
struct VolumeSwapReadReflectTests {

    private func makeBook(id: Int, title: String, unseen: Bool, playDate: Date?) -> BookRow {
        BookRow(
            id: id, title: title, author: nil, genre: nil,
            path: "/tmp/\(id).zip", dateAdded: Date(timeIntervalSince1970: 100),
            playDate: playDate, bookType: 0, fileType: 2,
            pages: 100, rating: 0, unseen: unseen,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil,
            series: "S", volume: Double(id))
    }

    /// `BookRow` と同じ内容の DB 行を作る（`insertBook` の公開 API は `BookRecord` を取る）。
    private func record(from row: BookRow) -> BookRecord {
        BookRecord(
            id: row.id, title: row.title, author: row.author, genre: row.genre,
            path: row.path, dateAdded: row.dateAdded, playDate: row.playDate,
            bookType: row.bookType, fileType: row.fileType, pages: row.pages,
            myRate: row.rating, unseen: row.unseen,
            keywordA: row.keywordA, keywordB: row.keywordB, keywordC: row.keywordC,
            neta: row.neta, series: row.series, volume: row.volume)
    }

    /// in-memory DB に 3 冊入れ、一覧を同じ順で持った `AppState` を返す。
    ///
    /// ★ `displayedBooks` と `sortedDisplayedBooks` の**両方**を用意する。
    /// グリッドが実際に描画するのは `sortedDisplayedBooks` の方
    /// （`LibraryBrowserView.swift` の `ForEach(appState.sortedDisplayedBooks)`）で、
    /// リストは `BookTableCoordinator` が `sortedDisplayedBooksVersion` を見て reloadData する。
    /// **`displayedBooks` だけを検査するテストは、画面に出ない更新を「成功」と判定してしまう**
    /// ―― G34b の初版はまさにそれで、実機 smoke B1 が NG になるまで緑のままだった。
    private func makeState() throws -> (AppState, Database) {
        let db = try Database.openInMemory()
        try db.migrate()
        let books = [
            makeBook(id: 1, title: "vol.1", unseen: false, playDate: Date(timeIntervalSince1970: 1_000)),
            makeBook(id: 2, title: "vol.2", unseen: true, playDate: nil),
            makeBook(id: 3, title: "vol.3", unseen: true, playDate: nil),
        ]
        for b in books { try db.insertBook(record(from: b)) }

        let state = AppState(bundleURL: URL(fileURLWithPath: "/tmp/g34b-test.stacknest"))
        state.database = db
        state.displayedBooks = books
        state.sortedDisplayedBooks = books
        return (state, db)
    }

    // MARK: - 1. ★★ 画面に出る配列に反映される（報告された症状そのもの）

    /// **これが B1 NG の再現テスト。** グリッドは `sortedDisplayedBooks` を描画する。
    @Test("巻送りした本が sortedDisplayedBooks 上で既読になり、読んだ日が入る")
    func swappedVolumeIsReflectedInTheRenderedList() throws {
        let (state, _) = try makeState()
        let at = Date(timeIntervalSince1970: 1_700_000_000)

        state.markVolumeAsReadAndReflect(bookID: 2, at: at)

        let rendered = try #require(state.sortedDisplayedBooks.first(where: { $0.id == 2 }))
        #expect(rendered.unseen == false)
        #expect(rendered.playDate?.timeIntervalSince1970 == at.timeIntervalSince1970)
    }

    /// リストビュー（NSTableView 版）は `sortedDisplayedBooksVersion` の変化で reloadData する。
    /// 配列だけ書き換えて version を bump しないと、**リスト表示では反映されない**。
    @Test("sortedDisplayedBooksVersion が bump される（リストの reloadData 用）")
    func renderedListVersionIsBumped() throws {
        let (state, _) = try makeState()
        let before = state.sortedDisplayedBooksVersion

        state.markVolumeAsReadAndReflect(bookID: 2, at: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(state.sortedDisplayedBooksVersion != before)
    }

    @Test("巻送りした本が displayedBooks 上でも既読になる")
    func swappedVolumeIsReflectedInDisplayedBooks() throws {
        let (state, _) = try makeState()
        let at = Date(timeIntervalSince1970: 1_700_000_000)

        state.markVolumeAsReadAndReflect(bookID: 2, at: at)

        let updated = try #require(state.displayedBooks.first(where: { $0.id == 2 }))
        #expect(updated.unseen == false)
        #expect(updated.playDate?.timeIntervalSince1970 == at.timeIntervalSince1970)
    }

    // MARK: - 2. ★ 並び順・要素数を動かさない（再ソートしていないことの証明）

    @Test("両方の配列で並び順と要素数が巻送り前後で変わらない")
    func listOrderAndCountAreUnchanged() throws {
        let (state, _) = try makeState()
        let beforeDisplayed = state.displayedBooks.map(\.id)
        let beforeSorted = state.sortedDisplayedBooks.map(\.id)

        state.markVolumeAsReadAndReflect(bookID: 2, at: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(state.displayedBooks.map(\.id) == beforeDisplayed)
        #expect(state.sortedDisplayedBooks.map(\.id) == beforeSorted)
        #expect(state.sortedDisplayedBooks.count == 3)
    }

    /// ★ 「読んだ日」降順で並べていても再ソートしない（ユーザー選択済みの方針）。
    /// `handleExternalBookChange` は並び順に影響する変更で再ソートするが、
    /// 巻送り経路は**意図的にその分岐を採らない** ―― 読み進めるたびに背景の一覧で
    /// その本が先頭へジャンプするのを避けるため。
    @Test("読んだ日ソート中でも巻送りで行が動かない")
    func doesNotResortEvenWhenTheSortKeyIsAffected() throws {
        let (state, _) = try makeState()
        state.librarySettings?.listViewSort = ColumnSort(column: .playDate, ascending: false)
        let beforeSorted = state.sortedDisplayedBooks.map(\.id)

        state.markVolumeAsReadAndReflect(bookID: 3, at: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(state.sortedDisplayedBooks.map(\.id) == beforeSorted)
    }

    /// 他の本は 1 フィールドも変わらない（行内更新が対象行だけに閉じている）。
    @Test("対象以外の本は変化しない")
    func otherBooksAreUntouched() throws {
        let (state, _) = try makeState()
        let othersBefore = state.sortedDisplayedBooks.filter { $0.id != 2 }

        state.markVolumeAsReadAndReflect(bookID: 2, at: Date(timeIntervalSince1970: 1_700_000_000))

        let othersAfter = state.sortedDisplayedBooks.filter { $0.id != 2 }
        #expect(othersAfter == othersBefore)
    }

    // MARK: - 2b. 詳細ペインへ反映される

    @Test("選択中の本を巻送りすると詳細ペインの値も更新される")
    func detailPaneReflectsTheChangeWhenSelected() throws {
        let (state, _) = try makeState()
        state.selectedBookIDs = [2]
        state.selectedBook = state.displayedBooks.first(where: { $0.id == 2 })
        let at = Date(timeIntervalSince1970: 1_700_000_000)

        state.markVolumeAsReadAndReflect(bookID: 2, at: at)

        #expect(state.selectedBook?.unseen == false)
        let inDetail = try #require(state.displayedSelectedBooks.first(where: { $0.id == 2 }))
        #expect(inDetail.unseen == false)
    }

    // MARK: - 3. ★ DB と画面が同じ時刻を持つ

    /// `db.markAsRead` と `displayedBooks` で別々に `Date()` を呼ぶと数ミリ秒ずれる。
    /// 表示上は無害だが、「読めた結果と表示を一致させる」という本プロジェクトの規律に反する。
    @Test("DB に書いた読んだ日と一覧の読んだ日が一致する")
    func databaseAndListAgreeOnTheTimestamp() throws {
        let (state, db) = try makeState()
        let at = Date(timeIntervalSince1970: 1_700_000_000)

        state.markVolumeAsReadAndReflect(bookID: 2, at: at)

        let fromDB = try #require(try db.fetchBook(id: 2))
        let fromList = try #require(state.sortedDisplayedBooks.first(where: { $0.id == 2 }))
        #expect(fromDB.unseen == false)
        #expect(fromDB.playDate?.timeIntervalSince1970 == at.timeIntervalSince1970)
        #expect(fromList.playDate == fromDB.playDate)
    }

    // MARK: - 4. 一覧に無い本でも DB は更新される

    /// 巻送り先が現在の絞り込み結果に入っていないことは普通に起こる
    /// （「未読のみ」表示・シェルフ表示・検索中など）。DB 更新まで諦めてはいけないし、
    /// 一覧へ勝手に足してもいけない。
    @Test("一覧に無い本でも DB は更新され、一覧には追加されない")
    func bookMissingFromTheListStillUpdatesTheDatabase() throws {
        let (state, db) = try makeState()
        let outsider = makeBook(id: 99, title: "vol.99", unseen: true, playDate: nil)
        try db.insertBook(record(from: outsider))
        let at = Date(timeIntervalSince1970: 1_700_000_000)

        state.markVolumeAsReadAndReflect(bookID: 99, at: at)

        let fromDB = try #require(try db.fetchBook(id: 99))
        #expect(fromDB.unseen == false)
        #expect(state.displayedBooks.count == 3)
        #expect(state.sortedDisplayedBooks.count == 3)
        #expect(!state.sortedDisplayedBooks.contains(where: { $0.id == 99 }))
    }
}
