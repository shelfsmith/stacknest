// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNestL10n

@Suite("L10nLang の解釈（G55）")
struct L10nLangTests {
    @Test("言語タグ: ja で始まれば ja、他はすべて en", arguments: [
        ("ja", L10nLang.ja), ("ja-JP", .ja), ("ja_JP", .ja), ("JA", .ja),
        ("en", .en), ("en-US", .en), ("fr-FR", .en), ("zh-Hans", .en), ("", .en),
    ])
    func languageTag(tag: String, expected: L10nLang) {
        #expect(L10nLang.from(languageTag: tag) == expected)
    }

    @Test("Accept-Language: q 値の最大を選ぶ", arguments: [
        ("en-US,ja;q=0.8", L10nLang.en),
        ("ja,en-US;q=0.9,en;q=0.8", .ja),
        ("fr;q=0.9, ja;q=0.95", .ja),
        ("de", .en),
        ("", .en),
    ])
    func acceptLanguage(header: String, expected: L10nLang) {
        #expect(L10nLang.from(acceptLanguage: header) == expected)
    }

    @Test("Accept-Language が無ければ en")
    func acceptLanguageMissing() {
        #expect(L10nLang.from(acceptLanguage: nil) == .en)
    }

    @Test("STACKNEST_LANG は preferredLanguages より優先")
    func envOverride() {
        #expect(L10nLang.from(preferredLanguages: ["ja-JP"], env: ["STACKNEST_LANG": "en"]) == .en)
        #expect(L10nLang.from(preferredLanguages: ["en-US"], env: ["STACKNEST_LANG": "ja"]) == .ja)
        #expect(L10nLang.from(preferredLanguages: ["ja-JP", "en"], env: [:]) == .ja)
        #expect(L10nLang.from(preferredLanguages: [], env: [:]) == .en)
    }

    /// Review Focus 4: アプリごとの言語設定。App は Bundle.main.preferredLocalizations を渡す。
    /// `resolve` は純関数（グローバル状態を読み書きしない）なので、並列実行しても安全に検証できる。
    /// `bootstrap` 自体はプロセス全体の `processDefault` を書き換えるため、テストからは直接呼ばない
    /// （Fix round 1: Swift Testing は並列実行するため、共有可変状態への書き込みはテスト間で競合する）。
    @Test("resolve は preferredLocalizations の先頭で言語を決める", arguments: [
        (["ja"], L10nLang.ja), (["en"], .en), (["ja", "en"], .ja), (["fr"], .en), ([], .en),
    ])
    func resolve(preferredLocalizations: [String], expected: L10nLang) {
        #expect(L10nLang.resolve(preferredLocalizations: preferredLocalizations) == expected)
    }

    /// requestOverride は current に勝ち、`withValue` のスコープの外には漏れない。
    /// `processDefault` へは書き込まない（Fix round 1: 他スイートと並列実行されるため）。
    @Test("requestOverride は current に勝ち、スコープの外には漏れない")
    func taskLocalOverride() {
        let outside = L10nLang.processDefault
        L10nLang.$requestOverride.withValue(.en) {
            #expect(L10nLang.current == .en)
        }
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(L10nLang.current == .ja)
        }
        #expect(L10nLang.current == outside)
        #expect(L10nLang.current == L10nLang.processDefault)
    }
}
