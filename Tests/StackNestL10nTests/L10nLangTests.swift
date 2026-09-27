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
    ])
    func acceptLanguage(header: String, expected: L10nLang) {
        #expect(L10nLang.from(acceptLanguage: header) == expected)
        // 明示されたヘッダは既定言語に左右されない
        #expect(L10nLang.from(acceptLanguage: header, fallback: .ja) == expected)
        #expect(L10nLang.from(acceptLanguage: header, fallback: .en) == expected)
    }

    /// 最終レビュー item 3: ヘッダが無い・空・解釈できないときはサーバの既定言語（ホストの言語）。
    @Test("Accept-Language が無い・空なら fallback（既定は processDefault）", arguments: [
        (nil, L10nLang.ja), (nil, .en), ("", .ja), ("", .en), (" , ", .ja), (" , ", .en),
    ] as [(String?, L10nLang)])
    func acceptLanguageMissing(header: String?, fallback: L10nLang) {
        #expect(L10nLang.from(acceptLanguage: header, fallback: fallback) == fallback)
    }

    @Test("fallback を省略すると processDefault")
    func acceptLanguageMissingUsesProcessDefault() {
        #expect(L10nLang.from(acceptLanguage: nil) == L10nLang.processDefault)
        #expect(L10nLang.from(acceptLanguage: "") == L10nLang.processDefault)
    }

    @Test("STACKNEST_LANG は preferredLanguages より優先")
    func envOverride() {
        #expect(L10nLang.from(preferredLanguages: ["ja-JP"], env: ["STACKNEST_LANG": "en"]) == .en)
        #expect(L10nLang.from(preferredLanguages: ["en-US"], env: ["STACKNEST_LANG": "ja"]) == .ja)
        #expect(L10nLang.from(preferredLanguages: ["ja-JP", "en"], env: [:]) == .ja)
        #expect(L10nLang.from(preferredLanguages: [], env: [:]) == .en)
    }

    /// 最終レビュー item 2: テストランナーでは、STACKNEST_LANG が無ければ OS の言語に関係なく ja。
    /// STACKNEST_LANG は引き続き最優先（CI の `STACKNEST_LANG=ja`、英語の手動確認 `STACKNEST_LANG=en`）。
    @Test("テストプロセスでは STACKNEST_LANG が無ければ ja")
    func testProcessDefaultsToJapanese() {
        #expect(L10nLang.from(preferredLanguages: ["en-US"], env: [:], isTestProcess: true) == .ja)
        #expect(L10nLang.from(preferredLanguages: [], env: [:], isTestProcess: true) == .ja)
        #expect(L10nLang.from(preferredLanguages: ["en-US"], env: ["STACKNEST_LANG": ""], isTestProcess: true) == .ja)
        #expect(L10nLang.from(preferredLanguages: ["ja-JP"], env: ["STACKNEST_LANG": "en"], isTestProcess: true) == .en)
        #expect(L10nLang.from(preferredLanguages: ["en-US"], env: [:], isTestProcess: false) == .en)
    }

    /// このテスト自身がテストランナーの中で動いていることを検出できる（読むだけ・書き込まない）。
    @Test("isTestProcess はテストランナーの中で true、processDefault は ja（STACKNEST_LANG 未指定時）")
    func detectsTestRunner() {
        #expect(L10nLang.isTestProcess)
        let forced = ProcessInfo.processInfo.environment["STACKNEST_LANG"] ?? ""
        if forced.isEmpty {
            #expect(L10nLang.processDefault == .ja)
        }
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
