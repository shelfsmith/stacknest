// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("列を表示にしたときにスクロールする先")
struct ColumnRevealPolicyTests {
    // リモートは先頭に "dl" 列が付く。ローカルは "title" が先頭。
    private let before = ["dl", "title", "author"]

    @Test("新たに現れた列が 1 つならその位置（先頭寄り・末尾の列でも実インデックスを返す）")
    func newlyShown() {
        #expect(ColumnRevealPolicy.newlyShownIndex(before: before, after: ["dl", "title", "author", "unseen"]) == 3)
        #expect(ColumnRevealPolicy.newlyShownIndex(before: before, after: ["dl", "genre", "title", "author"]) == 1)
    }

    @Test("OFF（列が減った）なら nil")
    func removed() {
        #expect(ColumnRevealPolicy.newlyShownIndex(before: before, after: ["dl", "title"]) == nil)
    }

    @Test("初回（before が空）は nil —— 起動時に勝手にスクロールしない")
    func firstInstall() {
        #expect(ColumnRevealPolicy.newlyShownIndex(before: [], after: before) == nil)
    }

    @Test("並べ替えだけなら nil")
    func reorderOnly() {
        #expect(ColumnRevealPolicy.newlyShownIndex(before: before, after: ["dl", "author", "title"]) == nil)
    }

    @Test("複数同時に現れたら nil（どれへ行くべきか決められない）")
    func multiple() {
        #expect(ColumnRevealPolicy.newlyShownIndex(before: before, after: ["dl", "title", "author", "unseen", "genre"]) == nil)
    }
}
