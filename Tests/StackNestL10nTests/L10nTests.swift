// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNestL10n

@Suite("L10n の引き当て（G55）")
struct L10nTests {
    private let table: [String: L10nEntry] = [
        "削除": L10nEntry("Delete"),
        "「%@」を削除しますか？": L10nEntry("Delete \u{201C}%@\u{201D}?"),
        "%lld 件選択中": L10nEntry(one: "%lld item selected", other: "%lld items selected"),
    ]

    @Test("ja はキーをそのまま返す")
    func japaneseIsKey() {
        #expect(L10n.text("削除", .ja, table: table) == "削除")
    }

    @Test("en は辞書の訳")
    func englishFromTable() {
        #expect(L10n.text("削除", .en, table: table) == "Delete")
    }

    @Test("訳が無ければ日本語を返す（落ちない）")
    func missingFallsBackToJapanese() {
        #expect(L10n.text("未登録の文言", .en, table: table) == "未登録の文言")
    }

    @Test("format は言語ごとの書式に差し込む")
    func format() {
        #expect(L10n.format("「%@」を削除しますか？", "棚A", lang: .ja, table: table) == "「棚A」を削除しますか？")
        #expect(L10n.format("「%@」を削除しますか？", "Shelf A", lang: .en, table: table) == "Delete \u{201C}Shelf A\u{201D}?")
    }

    @Test("plural は英語の単複を選ぶ", arguments: [(1, "1 item selected"), (2, "2 items selected"), (0, "0 items selected")])
    func plural(count: Int, expected: String) {
        #expect(L10n.plural("%lld 件選択中", count: count, count, lang: .en, table: table) == expected)
        #expect(L10n.plural("%lld 件選択中", count: count, count, lang: .ja, table: table) == "\(count) 件選択中")
    }

    /// Fix round 1 (issue 1): `lang` はラベル付きで varargs の後ろに置けるので、最初の引数が
    /// 言語に飲み込まれない。本番の（空の）辞書に対して呼び出し、日本語がそのまま整形されて返る
    /// （en の訳が無いので）ことと、`plural` も同様に動くことを確認する。
    @Test("公開 API: lang はラベル付きで varargs の後ろに置ける（実運用の空辞書に対して）")
    func publicAPILangLabelAfterVarargs() {
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(L10n.format("「%@」を削除しますか？", "x") == "「x」を削除しますか？")
            #expect(L10n.plural("%lld 件選択中", count: 2, 2) == "2 件選択中")
        }
    }

    @Test("書式指定子の抽出(多重集合・ソート済み)")
    func specifiers() {
        #expect(L10n.formatSpecifiers(in: "%lld 件の「%@」") == ["%@", "%lld"])
        #expect(L10n.formatSpecifiers(in: "%2$@ of %1$lld") == ["%@", "%lld"])
        #expect(L10n.formatSpecifiers(in: "100%% done") == [])
        #expect(L10n.formatSpecifiers(in: "%.1f MB") == ["%.1f"])
    }

    /// Fix round 1 (issue 2): 引数として消費される順で並べる。位置指定 `%N$` があれば N の昇順、
    /// 無ければ左から右。並び替え（ソート）ではないので、キーと訳で引数の順序が違えば一致しない。
    @Test("formatSpecifierSequence: 引数順（並び替えではない）", arguments: [
        ("%@ の %lld 件", ["%@", "%lld"]),
        ("%lld items in %@", ["%lld", "%@"]),
        ("%2$@ of %1$lld", ["%lld", "%@"]),
        ("%.1f MB", ["%.1f"]),
        ("100%% done", []),
    ])
    func specifierSequence(input: String, expected: [String]) {
        #expect(L10n.formatSpecifierSequence(in: input) == expected)
    }

    @Test("formatSpecifierSequence: 引数の順序が違えば一致しない（ソートでは検出できない例）")
    func specifierSequenceOrderMismatchIsDetected() {
        let key = L10n.formatSpecifierSequence(in: "%@ の %lld 件")
        let mismatchedTranslation = L10n.formatSpecifierSequence(in: "%lld items in %@")
        #expect(key != mismatchedTranslation)
        // 多重集合として見れば同じなので、旧 formatSpecifiers（ソート済み）では区別できないことも明示しておく。
        #expect(L10n.formatSpecifiers(in: "%@ の %lld 件") == L10n.formatSpecifiers(in: "%lld items in %@"))
    }

    /// Review Focus 3: 本番の全辞書で、キーと訳の書式指定子が **引数の順序まで含めて** 一致する。
    @Test("全辞書: キーと英訳の書式指定子が引数順で一致する")
    func allTablesSpecifiersMatch() {
        for (key, entry) in L10nTable.all {
            let k = L10n.formatSpecifierSequence(in: key)
            if let p = entry.enPlural {
                #expect(L10n.formatSpecifierSequence(in: p.one) == k, "one: \(key)")
                #expect(L10n.formatSpecifierSequence(in: p.other) == k, "other: \(key)")
            } else {
                #expect(L10n.formatSpecifierSequence(in: entry.en) == k, "\(key)")
            }
        }
    }

    @Test("全辞書: 単位をまたいだ重複キーが無い")
    func noDuplicateKeys() {
        #expect(L10nTable.duplicateKeys.isEmpty, "\(L10nTable.duplicateKeys)")
    }
}
