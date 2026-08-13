// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServerAPI

/// G35b: リモート庫の一覧を「その場で既読にする」更新。
///
/// ローカルは G34b で、巻送りで開いた瞬間に既読化＋一覧へ反映するようにした。
/// リモートは同じことをしておらず、**その巻を離れるまで一覧では未読のまま**だった。
/// 揃えるための小さな純関数（`RemoteLibraryState` は生成に多くの依存が要りテストしづらいため、
/// 判定を外へ出して `swift test` で守る ―― `ResumeGate` / `WatchScanPlanner` と同じ流儀）。
///
/// ★ **データの欠損ではない。** サーバ側は `windowWillClose` → `flushPersistNow` →
/// `postProgress` → `markAsRead` で必ず追いつく。ここで直すのは**一覧表示のタイミング差**。
@Suite("BookListItemDTO 一覧の既読化（G35b）")
struct BookListMarkReadTests {

    private func item(id: Int, unseen: Bool, lastReadAt: Date? = nil,
                      lastPage: Int? = nil) -> BookListItemDTO {
        BookListItemDTO(
            id: id, title: "B\(id)", author: nil, series: nil, volume: nil,
            rating: 0, unseen: unseen, bookType: 0, pages: nil,
            lastPage: lastPage, lastReadAt: lastReadAt,
            dateAdded: Date(timeIntervalSince1970: 0), hasCover: false, coverVersion: nil)
    }

    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 1. 対象の本が既読になる

    @Test("未読の本が既読になり、読んだ日が入る")
    func marksTheTargetRead() {
        let books = [item(id: 1, unseen: false), item(id: 2, unseen: true), item(id: 3, unseen: true)]

        let updated = books.markingRead(bookID: 2, at: at)

        let target = updated.first { $0.id == 2 }
        #expect(target?.unseen == false)
        #expect(target?.lastReadAt == at)
    }

    /// ★ 既読の本を開き直したときも「読んだ日」は更新されるべき。
    /// 既存のリモート初回オープンは `unseen` が true のときだけ更新していたため、
    /// **既読本を読み返しても読んだ日が古いまま**だった。
    @Test("既に既読の本でも読んだ日は更新される")
    func refreshesReadDateOnAlreadyReadBook() {
        let old = Date(timeIntervalSince1970: 1_000)
        let books = [item(id: 1, unseen: false, lastReadAt: old)]

        let updated = books.markingRead(bookID: 1, at: at)

        #expect(updated[0].unseen == false)
        #expect(updated[0].lastReadAt == at)
    }

    // MARK: - 2. 並び順・要素数を動かさない

    /// ローカル（G34b）と同じ方針: **行の値だけ差し替え、並び替えない。**
    @Test("並び順と要素数が変わらない")
    func keepsOrderAndCount() {
        let books = [item(id: 5, unseen: true), item(id: 3, unseen: true), item(id: 9, unseen: true)]

        let updated = books.markingRead(bookID: 3, at: at)

        #expect(updated.map(\.id) == [5, 3, 9])
        #expect(updated.count == 3)
    }

    @Test("対象以外の本は変化しない")
    func leavesOtherBooksAlone() {
        let books = [item(id: 1, unseen: true), item(id: 2, unseen: true)]

        let updated = books.markingRead(bookID: 2, at: at)

        #expect(updated[0].unseen == true)
        #expect(updated[0].lastReadAt == nil)
    }

    // MARK: - 3. lastPage は触らない

    /// ★ 巻送り直後の読書位置はまだ確定していない。ここで書くと、確定していない値で
    /// 一覧を上書きすることになる（`persistState` が正しい値で更新する）。
    @Test("lastPage は変更しない")
    func doesNotTouchLastPage() {
        let books = [item(id: 1, unseen: true, lastPage: 42)]

        let updated = books.markingRead(bookID: 1, at: at)

        #expect(updated[0].lastPage == 42)
    }

    // MARK: - 4. 一覧に無い本

    /// 巻送り先が現在の絞り込み結果に入っていないことは普通に起こる。
    /// **勝手に足さない**（ローカルと同じ）。
    @Test("一覧に無い ID なら何も変わらない")
    func unknownIDIsANoOp() {
        let books = [item(id: 1, unseen: true), item(id: 2, unseen: true)]

        let updated = books.markingRead(bookID: 99, at: at)

        #expect(updated.count == 2)
        #expect(updated.map(\.id) == [1, 2])
        #expect(updated[0].unseen == true)
        #expect(updated[1].unseen == true)
    }

    @Test("空の一覧でも落ちない")
    func emptyList() {
        #expect([BookListItemDTO]().markingRead(bookID: 1, at: at).isEmpty)
    }
}
