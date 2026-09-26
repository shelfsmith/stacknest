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
    @Test("bootstrap は preferredLocalizations の先頭で processDefault を決める")
    func bootstrap() {
        let saved = L10nLang.processDefault
        defer { L10nLang.processDefault = saved }
        L10nLang.bootstrap(preferredLocalizations: ["ja"])
        #expect(L10nLang.processDefault == .ja)
        L10nLang.bootstrap(preferredLocalizations: ["en"])
        #expect(L10nLang.processDefault == .en)
        L10nLang.bootstrap(preferredLocalizations: [])
        #expect(L10nLang.processDefault == .en)
    }

    @Test("requestOverride は current に勝ち、スコープの外には漏れない")
    func taskLocalOverride() async {
        let saved = L10nLang.processDefault
        defer { L10nLang.processDefault = saved }
        L10nLang.processDefault = .ja
        await L10nLang.$requestOverride.withValue(.en) {
            #expect(L10nLang.current == .en)
        }
        #expect(L10nLang.current == .ja)
    }
}
