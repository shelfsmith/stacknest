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

    /// spec §4.4: 区切り文字を含むタグは同期しない。
    @Test func tagsContainingTheSeparatorAreNotSyncable() {
        #expect(FinderTagEntry.isSyncable("SF") == true)
        #expect(FinderTagEntry.isSyncable("SF, ファンタジー") == false)
        #expect(FinderTagEntry.isSyncable("SF,ファンタジー") == true,
                "区切りは \", \"（カンマ+空白）。カンマだけなら分裂しない")
        #expect(FinderTagEntry.isSyncable("") == false, "空のタグは同期しない")
    }
}
