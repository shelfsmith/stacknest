// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Database update patch API")
struct UpdateBookTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    @Test func updateSingleField() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "Original"))
        var p = BookPatch(); p.author = "Yamada"
        try db.updateBook(id: 1, patch: p)
        let book = try db.fetchBook(id: 1)
        #expect(book?.author == "Yamada")
        #expect(book?.title == "Original")
    }

    @Test func updateMultipleFields() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        let p = BookPatch(rating: 5, unseen: false, bookType: 3)
        try db.updateBook(id: 1, patch: p)
        let book = try db.fetchBook(id: 1)
        #expect(book?.rating == 5)
        #expect(book?.unseen == false)
        #expect(book?.bookType == 3)
    }

    @Test func emptyPatchDoesNothing() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBook(id: 1, patch: BookPatch())
        let book = try db.fetchBook(id: 1)
        #expect(book?.title == "T")
    }

    @Test func updateMemoField() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBook(id: 1, patch: BookPatch(memo: "important note"))
        let book = try db.fetchBook(id: 1)
        #expect(book?.memo == "important note")
    }

    @Test func emptyTitleIsRejected() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        #expect(throws: BookPatchError.emptyTitle) {
            try db.updateBook(id: 1, patch: BookPatch(title: ""))
        }
    }

    @Test func whitespaceOnlyTitleIsRejected() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        #expect(throws: BookPatchError.emptyTitle) {
            try db.updateBook(id: 1, patch: BookPatch(title: "   "))
        }
    }

    @Test func ratingClampedToValidRange() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBook(id: 1, patch: BookPatch(rating: 99))
        #expect(try db.fetchBook(id: 1)?.rating == 5)
        try db.updateBook(id: 1, patch: BookPatch(rating: -3))
        #expect(try db.fetchBook(id: 1)?.rating == 0)
    }

    @Test func bookTypeClampedToValidRange() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBook(id: 1, patch: BookPatch(bookType: 99))
        #expect(try db.fetchBook(id: 1)?.bookType == 5)
        try db.updateBook(id: 1, patch: BookPatch(bookType: -1))
        #expect(try db.fetchBook(id: 1)?.bookType == 0)
    }

    @Test func unseenFalseTransitionFromTrue() throws {
        let db = try setupDB()
        // Insert a row with unseen: true (testInstance defaults to false, override here).
        try db.insertBook(BookRow(
            id: 1, title: "T", author: nil, genre: nil, path: nil,
            dateAdded: Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil
        ))
        try db.updateBook(id: 1, patch: BookPatch(unseen: false))
        #expect(try db.fetchBook(id: 1)?.unseen == false)
    }

    @Test func bulkUpdateAppliesToAllIDs() throws {
        let db = try setupDB()
        for i in 1...3 {
            try db.insertBook(BookRow.testInstance(id: i, title: "B\(i)"))
        }
        try db.updateBooks(ids: [1, 2, 3], patch: BookPatch(rating: 4))
        for id in 1...3 {
            #expect(try db.fetchBook(id: id)?.rating == 4)
        }
    }

    @Test func bulkUpdateLeavesUnselectedBooksUntouched() throws {
        let db = try setupDB()
        for i in 1...5 {
            try db.insertBook(BookRow.testInstance(id: i, title: "B\(i)"))
        }
        try db.updateBooks(ids: [2, 4], patch: BookPatch(genre: "SF"))
        #expect(try db.fetchBook(id: 2)?.genre == "SF")
        #expect(try db.fetchBook(id: 4)?.genre == "SF")
        #expect(try db.fetchBook(id: 1)?.genre == nil)
        #expect(try db.fetchBook(id: 3)?.genre == nil)
        #expect(try db.fetchBook(id: 5)?.genre == nil)
    }

    /// Task C9: コンテキストメニューで複数選択中に「種類」を選ぶと
    /// 選択行すべての bookType が更新される。AppState.setBookTypeForSelected →
    /// applyPatch(bookIDs:) → updateBooks(ids:, patch:) の DB レイヤ契約を固定する。
    @Test func bulkUpdateAppliesBookTypeToAllIDs() throws {
        let db = try setupDB()
        // 3 冊挿入 (デフォルト bookType=0=「厚い本」)
        for i in 1...3 {
            try db.insertBook(BookRow.testInstance(id: i, title: "B\(i)"))
        }
        // 全 3 冊を bookType=2 ("一部もの") に bulk update
        try db.updateBooks(ids: [1, 2, 3], patch: BookPatch(bookType: 2))
        for id in 1...3 {
            #expect(try db.fetchBook(id: id)?.bookType == 2)
        }
    }

    /// Task C9: 選択外の本の bookType は触られない (右クリック行 ∉ selection の
    /// macOS 慣習との整合)。
    @Test func bulkUpdateBookTypeLeavesUnselectedUntouched() throws {
        let db = try setupDB()
        for i in 1...5 {
            try db.insertBook(BookRow.testInstance(id: i, title: "B\(i)"))
        }
        // 2 冊だけ bookType=4 ("テキスト") に更新
        try db.updateBooks(ids: [2, 4], patch: BookPatch(bookType: 4))
        #expect(try db.fetchBook(id: 2)?.bookType == 4)
        #expect(try db.fetchBook(id: 4)?.bookType == 4)
        // 1, 3, 5 は default (0) のまま
        #expect(try db.fetchBook(id: 1)?.bookType == 0)
        #expect(try db.fetchBook(id: 3)?.bookType == 0)
        #expect(try db.fetchBook(id: 5)?.bookType == 0)
    }

    @Test func bulkUpdateWithEmptyIDsIsNoOp() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBooks(ids: [], patch: BookPatch(rating: 5))
        #expect(try db.fetchBook(id: 1)?.rating == 0)
    }

    @Test func bulkUpdateWithEmptyPatchIsNoOp() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBooks(ids: [1], patch: BookPatch())
        #expect(try db.fetchBook(id: 1)?.rating == 0)
    }

    @Test func bulkUpdateRejectsEmptyTitle() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        #expect(throws: BookPatchError.emptyTitle) {
            try db.updateBooks(ids: [1], patch: BookPatch(title: ""))
        }
    }

    // MARK: - Task マ1-2: multi-value normalization on updateBook

    /// Detail Pane 相当: カンマ区切り空白なし ("値A,値B") で author を保存すると
    /// DB 読み戻し時に `, ` 区切り ("値A, 値B") に正規化される。
    @Test func multiValueAuthorNormalizedOnUpdate() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBook(id: 1, patch: BookPatch(author: "値A,値B"))
        let book = try db.fetchBook(id: 1)
        #expect(book?.author == "値A, 値B")
    }

    /// genre フィールドも同様に正規化される。
    @Test func multiValueGenreNormalizedOnUpdate() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBook(id: 1, patch: BookPatch(genre: "SF,ファンタジー,ホラー"))
        let book = try db.fetchBook(id: 1)
        #expect(book?.genre == "SF, ファンタジー, ホラー")
    }

    /// keywordA/B/C も正規化される。
    @Test func multiValueKeywordsNormalizedOnUpdate() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBook(id: 1, patch: BookPatch(keywordA: "A,B", keywordB: "C,D", keywordC: "E,F"))
        let book = try db.fetchBook(id: 1)
        #expect(book?.keywordA == "A, B")
        #expect(book?.keywordB == "C, D")
        #expect(book?.keywordC == "E, F")
    }

    /// 正規化後に buildBrowserClause の LIKE 4-pattern でヒットする。
    @Test func multiValueNormalizedValueIsFoundByBrowserClause() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        // 空白なしカンマ区切りで保存
        try db.updateBook(id: 1, patch: BookPatch(author: "値A,値B"))
        // 正規化後: "値A, 値B" → buildBrowserClause で "値A" で検索 → ヒットする
        let results = try db.searchBooks(
            query: "",
            sidebarScope: .library,
            browserConstraints: [("author", "値A")]
        )
        #expect(results.map(\.id).contains(1))
    }

    /// neta フィールドも正規化される。
    @Test func multiValueNetaNormalizedOnUpdate() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBook(id: 1, patch: BookPatch(neta: "ネタA,ネタB"))
        let book = try db.fetchBook(id: 1)
        #expect(book?.neta == "ネタA, ネタB")
    }

    /// memo は multi-value 対象外なので正規化されない。
    @Test func memoIsNotNormalizedOnUpdate() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "T"))
        try db.updateBook(id: 1, patch: BookPatch(memo: "note,with,commas"))
        let book = try db.fetchBook(id: 1)
        #expect(book?.memo == "note,with,commas")
    }
}
