// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNest

/// G55 S2-C: 同じ日本語を 2 つの文脈で使っていた箇所のうち、英訳が合わない側を英語のドット区切りキー
/// （`String(localized: "key", defaultValue: "日本語")`）に分けた。日本語 UI は defaultValue のまま
/// 一字一句変わらず、英語 UI だけが新しい訳になることを、ビルドされたアプリの ja.lproj / en.lproj で確かめる。
///
/// 翻訳は `tools/l10n/fragments/S2C.json` にあり、`merge_fragments.py` で `Localizable.xcstrings` に
/// 取り込む（`ja` と `en` の両方を書く）。取り込むまで en.lproj にキーが無いので、英語側のテストは
/// ソースのカタログにキーが入るまで無効にしてある（取り込めば自動で有効になる）。
@Suite("文脈ごとに分けたキー（G55 S2-C）")
struct SplitKeyLocalizationTests {
    /// (key, 呼び出し側の defaultValue ＝元の日本語, 英訳)
    static let splits: [(key: String, ja: String, en: String)] = [
        ("settings.maintenance.regenerateCovers", "表紙を再生成", "Regenerate Covers"),
        ("sidebar.section.smartShelves", "スマートシェルフ", "Smart Shelves"),
        ("sharing.section.connection", "接続", "Connection"),
        ("settings.tab.labels", "ラベル", "Labels"),
        ("remote.server.rename", "変更", "Rename"),
        ("remote.batch.noBooksSelected", "書籍が選択されていません", "No books selected."),
        ("menu.toggleUnread", "未読チェック", "Toggle Unread"),
    ]

    /// ソースの String Catalog（`App/StackNest/Localizable.xcstrings`）に分けたキーがすべて入っているか。
    static var catalogHasSplitKeys: Bool {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StackNest/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = obj["strings"] as? [String: Any] else { return false }
        return splits.allSatisfy { strings[$0.key] != nil }
    }

    private func lproj(_ lang: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: lang, ofType: "lproj"), "\(lang).lproj がアプリに無い")
        return try #require(Bundle(path: path))
    }

    /// 実行時の `String(localized:defaultValue:)` と同じく、表に無ければ defaultValue が返る引き方。
    private func lookup(_ bundle: Bundle, _ key: String, default value: String) -> String {
        bundle.localizedString(forKey: key, value: value, table: "Localizable")
    }

    @Test("日本語ではキーではなく元の日本語が出る")
    func japaneseShowsTheOriginalText() throws {
        let ja = try lproj("ja")
        for s in Self.splits {
            #expect(lookup(ja, s.key, default: s.ja) == s.ja, "\(s.key)")
        }
    }

    @Test("英語では文脈に合った訳が出る",
          .disabled(if: !SplitKeyLocalizationTests.catalogHasSplitKeys, "S2C.json をカタログへ取り込むまで無効"))
    func englishShowsTheSplitTranslation() throws {
        let en = try lproj("en")
        for s in Self.splits {
            #expect(lookup(en, s.key, default: s.ja) == s.en, "\(s.key)")
        }
    }
}
