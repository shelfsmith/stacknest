// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

/// spec §4.3 の実測: `com.apple.metadata:_kMDItemUserTags` は binary plist の文字列配列で、
/// 色付きタグは `"名前\n色番号"`、色無しは `"名前"`。実物から確認した値は `"レッド\n6"`。
@Suite("Finder タグ 1 件の解析（G39）")
struct FinderTagEntryTests {
    @Test func parsesAColouredTag() {
        let e = FinderTagEntry.parse("レッド\n6")
        #expect(e.name == "レッド")
        #expect(e.colorIndex == 6)
    }

    @Test func parsesAColourlessTag() {
        let e = FinderTagEntry.parse("あとで読む")
        #expect(e.name == "あとで読む")
        #expect(e.colorIndex == nil)
    }

    /// ★ 往復で色番号が保たれること。ここが崩れると**書き戻しでユーザーのタグ色が全部消える**。
    @Test func roundTripsKeepingTheColour() {
        for raw in ["レッド\n6", "あとで読む", "名前\n0", "名前\n7"] {
            #expect(FinderTagEntry.parse(raw).rawValue == raw, "往復で \(raw) が変わってはいけない")
        }
    }

    /// ★ 見慣れない色番号でも**そのまま保つ**こと。
    ///
    /// Finder が書くのは 0〜7 だけだが、他のアプリが書いた値が入っていることはありうる。
    /// **理解できない値を 0〜7 に丸めたり捨てたりすると、他人のデータを壊す。**
    /// 往復で保つのが正しい。レビューで「負値を捨てる改変を誰も検出しない」穴として見つかった。
    ///
    /// 保てるのは**整数の正準表記**に限る。`"007"` のような先頭ゼロは `"7"` に正規化されるが、
    /// Finder はそれを書かないので実害はない（境界としてここに記録しておく）。
    @Test func keepsAnUnfamiliarColourIndexAsItIs() {
        for raw in ["名前\n-1", "名前\n0", "名前\n7", "名前\n42"] {
            #expect(FinderTagEntry.parse(raw).rawValue == raw, "\(raw) を丸めたり捨てたりしてはいけない")
        }
        #expect(FinderTagEntry.parse("名前\n007").rawValue == "名前\n7",
                "先頭ゼロは正準化される（Finder は書かないので実害なし・境界の記録）")
    }

    /// 名前自体に改行が入っている異常データでも壊れない（最初の改行で切る）。
    @Test func onlyTheFirstNewlineSeparatesTheColour() {
        let e = FinderTagEntry.parse("変な\n名前\n6")
        #expect(e.name == "変な")
        #expect(e.colorIndex == nil, "色番号として読めない残りは色無し扱い")
    }

    @Test func aNonNumericSuffixIsNotAColour() {
        let e = FinderTagEntry.parse("名前\nあか")
        #expect(e.name == "名前")
        #expect(e.colorIndex == nil)
    }

    /// spec §4.4: **往復で元に戻らない名前は同期しない。**
    ///
    /// 当初は「`", "` を含むか」で判定していたが、`MultiValueParser.split` は
    /// **`","` で切って前後の空白を trim** するので、それでは漏れる。
    /// レビューが実測で見つけた: `"SF,ファンタジー"` は素通りして
    /// **1 個の Finder タグが 2 個の値に割れ**、しかも `skippedTags` に載らない。
    @Test func onlyNamesThatSurviveTheRoundTripAreSyncable() {
        #expect(FinderTagEntry.isSyncable("SF") == true)
        #expect(FinderTagEntry.isSyncable("マンガ") == true)

        #expect(FinderTagEntry.isSyncable("SF, ファンタジー") == false, "区切りそのもの")
        #expect(FinderTagEntry.isSyncable("SF,ファンタジー") == false,
                "★ 空白が無くても split はカンマで割る。当初の判定はここを見逃していた")
        #expect(FinderTagEntry.isSyncable("SF ") == false,
                "★ 末尾の空白は trim される。往復で戻らない")
        #expect(FinderTagEntry.isSyncable(" SF") == false, "先頭の空白も同じ")
        #expect(FinderTagEntry.isSyncable(" ") == false, "空白だけの名前は split が空にする")
        #expect(FinderTagEntry.isSyncable("") == false, "空のタグは同期しない")
    }
}
