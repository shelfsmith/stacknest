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
        #expect(L10n.format("「%@」を削除しますか？", .ja, table: table, "棚A") == "「棚A」を削除しますか？")
        #expect(L10n.format("「%@」を削除しますか？", .en, table: table, "Shelf A") == "Delete \u{201C}Shelf A\u{201D}?")
    }

    @Test("plural は英語の単複を選ぶ", arguments: [(1, "1 item selected"), (2, "2 items selected"), (0, "0 items selected")])
    func plural(count: Int, expected: String) {
        #expect(L10n.plural("%lld 件選択中", count: count, .en, table: table, count) == expected)
        #expect(L10n.plural("%lld 件選択中", count: count, .ja, table: table, count) == "\(count) 件選択中")
    }

    @Test("書式指定子の抽出(位置指定は位置を外して並べる)")
    func specifiers() {
        #expect(L10n.formatSpecifiers(in: "%lld 件の「%@」") == ["%@", "%lld"])
        #expect(L10n.formatSpecifiers(in: "%2$@ of %1$lld") == ["%@", "%lld"])
        #expect(L10n.formatSpecifiers(in: "100%% done") == [])
        #expect(L10n.formatSpecifiers(in: "%.1f MB") == ["%.1f"])
    }

    /// Review Focus 3: 本番の全辞書で、キーと訳の書式指定子が一致する。
    @Test("全辞書: キーと英訳の書式指定子が一致する")
    func allTablesSpecifiersMatch() {
        for (key, entry) in L10nTable.all {
            let k = L10n.formatSpecifiers(in: key)
            if let p = entry.enPlural {
                #expect(L10n.formatSpecifiers(in: p.one) == k, "one: \(key)")
                #expect(L10n.formatSpecifiers(in: p.other) == k, "other: \(key)")
            } else {
                #expect(L10n.formatSpecifiers(in: entry.en) == k, "\(key)")
            }
        }
    }

    @Test("全辞書: 単位をまたいだ重複キーが無い")
    func noDuplicateKeys() {
        #expect(L10nTable.duplicateKeys.isEmpty, "\(L10nTable.duplicateKeys)")
    }
}
