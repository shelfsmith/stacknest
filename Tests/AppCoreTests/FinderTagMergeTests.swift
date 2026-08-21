// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

/// spec §4 の 3 方向マージ。**単純な合併（ユニオン）では削除が伝わらない** ——
/// 一度付いたタグはどちらで消しても復活してしまう。前回同期値が要る理由がこれ。
@Suite("Finder タグの 3 方向マージ（G39）")
struct FinderTagMergeTests {
    private func m(_ base: Set<String>?, _ finder: Set<String>, _ lib: Set<String>) -> Set<String> {
        FinderTagMerge.merge(baseline: base, finder: finder, library: lib).merged
    }

    @Test func addedInFinder()  { #expect(m([], ["a"], []) == ["a"]) }
    @Test func addedInLibrary() { #expect(m([], [], ["a"]) == ["a"]) }

    /// ★ 削除が伝わること。ユニオンだとここが ["a"] になって復活する。
    @Test func removedInFinder()  { #expect(m(["a"], [], ["a"]) == []) }
    @Test func removedInLibrary() { #expect(m(["a"], ["a"], []) == []) }

    @Test func addedIndependentlyOnBothSides() { #expect(m([], ["a"], ["a"]) == ["a"]) }
    @Test func unchanged() { #expect(m(["a"], ["a"], ["a"]) == ["a"]) }

    /// baseline から見て**変化が見える側が勝つ**。
    ///
    /// 当初これを「真の競合（追加 vs 削除）は追加を優先」と説明していたが、
    /// **その状態は到達不能**だった（削除は baseline にあること、追加は無いことを要求するため）。
    /// ここが固定しているのは「片側の削除が伝わり、もう片側の追加も同時に通る」ことである。
    @Test func theChangeThatIsVisibleAgainstTheBaselineWins() {
        // 前回 ["a"]、Finder は "b" を足し、StackNest は "a" を消した
        #expect(m(["a"], ["a", "b"], []) == ["b"], "片側だけの削除は伝わる")
        // 前回なし、Finder が "a" を足し、StackNest も同時に "a" を足して消した…は表現できないので
        // 「前回あり・両方に無い」= 双方で削除
        #expect(m(["a"], [], []) == [])
    }

    /// 初回（前回値が無い）は合併でよい。まだ何も同期していないので削除の情報が無い。
    @Test func theFirstSyncUnionsBothSides() {
        #expect(m(nil, ["a"], ["b"]) == ["a", "b"])
    }

    /// どちら側が変わったかを返す（書き戻しの要否を決めるのに使う）。
    @Test func reportsWhichSideNeedsWriting() {
        let r = FinderTagMerge.merge(baseline: ["a"], finder: ["a"], library: ["a", "b"])
        #expect(r.merged == ["a", "b"])
        #expect(r.changedInFinder == true, "Finder 側に b を書き足す必要がある")
        #expect(r.changedInLibrary == false, "StackNest 側は既に一致している")
    }

    /// ★ 件数が同じでも中身が違えば「変わった」と判定すること。
    ///
    /// `merged != finder` を `merged.count != finder.count` に壊しても、既存のテストは
    /// **全部通ってしまう**（レビューで見つかった穴）。既存テストはどれも要素数が動くケースだけを
    /// 作っていたため。実害は明白で、**Finder への書き戻しが起きない**。
    /// 反例: 前回 {a}・Finder {a}・StackNest {b} → merged は {b}（a は StackNest 側で消された）。
    /// 件数はどちらも 1 だが、Finder には b を書かなければならない。
    @Test func aSameSizedButDifferentSetStillCountsAsChanged() {
        let r = FinderTagMerge.merge(baseline: ["a"], finder: ["a"], library: ["b"])
        #expect(r.merged == ["b"])
        #expect(r.changedInFinder == true, "件数が同じでも中身が違えば書き戻しが要る")
        #expect(r.changedInLibrary == false, "StackNest 側は既に一致している")
    }

    @Test func emptyEverywhereIsANoOp() {
        let r = FinderTagMerge.merge(baseline: [], finder: [], library: [])
        #expect(r.merged.isEmpty)
        #expect(r.changedInFinder == false)
        #expect(r.changedInLibrary == false)
    }
}
