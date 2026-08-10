// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// G34b Task B1: `BookRow.markedRead(at:)`。
///
/// 巻送りで開いた本を一覧へ**その場で**反映するために使う。`refreshDisplayedBooks()` の
/// ような再取得は行わない ―― 「読んだ日」降順で並べていると巻送りのたびにその本が先頭へ
/// ジャンプし、「未読のみ」表示だと一覧から消えてしまうため（`resolveVolume` の
/// 元コメントが避けていた挙動。ユーザー選択済みの方針）。
@Suite("BookRow.markedRead（巻送りの既読反映・G34b）")
struct BookRowMarkedReadTests {
    private func makeBook(id: Int = 42, unseen: Bool, playDate: Date?) -> BookRow {
        BookRow(
            id: id, title: "Sample", author: "Author", genre: "Genre",
            path: "/tmp/sample.zip", dateAdded: Date(timeIntervalSince1970: 100), playDate: playDate,
            bookType: 3, fileType: 2, pages: 180, rating: 4, unseen: unseen,
            keywordA: "ka", keywordB: "kb", keywordC: "kc", neta: "neta", memo: "memo",
            series: "Series", volume: 7,
            coverImageName: "cover.jpg", coverCropRect: nil,
            pageDirection: .rightToLeft, contentHash: "abc", fileSize: 1234, fileMtime: 5678)
    }

    @Test("未読の本を既読にし、読んだ日を渡した時刻にする")
    func marksUnseenBookAsRead() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = makeBook(unseen: true, playDate: nil).markedRead(at: at)

        #expect(updated.unseen == false)
        #expect(updated.playDate == at)
    }

    /// ★ 他のフィールドを 1 つでも落とすと、一覧の該当行だけが壊れる（タイトルが消える等）。
    /// `BookRow` は全フィールドが `let` で、更新は全項目を書き直す形になるため、
    /// 取りこぼしが起きやすい。全フィールドを明示的に固定する。
    @Test("既読化以外のフィールドは一切変わらない")
    func preservesEveryOtherField() {
        let original = makeBook(unseen: true, playDate: nil)
        let updated = original.markedRead(at: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(updated.id == original.id)
        #expect(updated.title == original.title)
        #expect(updated.author == original.author)
        #expect(updated.genre == original.genre)
        #expect(updated.path == original.path)
        #expect(updated.dateAdded == original.dateAdded)
        #expect(updated.bookType == original.bookType)
        #expect(updated.fileType == original.fileType)
        #expect(updated.pages == original.pages)
        #expect(updated.rating == original.rating)
        #expect(updated.keywordA == original.keywordA)
        #expect(updated.keywordB == original.keywordB)
        #expect(updated.keywordC == original.keywordC)
        #expect(updated.neta == original.neta)
        #expect(updated.memo == original.memo)
        #expect(updated.series == original.series)
        #expect(updated.volume == original.volume)
        #expect(updated.coverImageName == original.coverImageName)
        #expect(updated.coverCropRect == original.coverCropRect)
        #expect(updated.pageDirection == original.pageDirection)
        #expect(updated.contentHash == original.contentHash)
        #expect(updated.fileSize == original.fileSize)
        #expect(updated.fileMtime == original.fileMtime)
    }

    /// 同じ本を続けて巻送りで開き直すことは普通に起こる（前巻へ戻ってまた進む等）。
    @Test("既読の本に適用しても壊れず、読んだ日だけが進む")
    func isIdempotentAndAdvancesPlayDate() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = Date(timeIntervalSince1970: 1_700_000_600)
        let book = makeBook(unseen: false, playDate: first)

        let updated = book.markedRead(at: second)

        #expect(updated.unseen == false)
        #expect(updated.playDate == second)
    }
}
