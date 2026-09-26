// SPDX-License-Identifier: MIT
import Testing
import Foundation
import StackNestL10n
@testable import StackNest

/// G55・Review Focus 4: App の表示言語（アプリごとの言語設定を含む）と、AppCore が使う L10nLang を一致させる。
///
/// `StackNestApp.resolveLanguage` は `L10nLang.resolve(preferredLocalizations:)` を呼ぶだけの
/// 純関数を経由する。テストは並列に 1 プロセス内で走るため、グローバルな
/// `L10nLang.processDefault` を書き換えるテストは書かない（他のテストと競合する）。
@Suite("起動時の言語の決定（G55）")
@MainActor
struct LanguageBootstrapTests {
    @Test("StackNestApp.resolveLanguage は preferredLocalizations の先頭要素に従う")
    func resolveLanguageFollowsPreferredLocalizations() {
        #expect(StackNestApp.resolveLanguage(preferredLocalizations: ["en"]) == .en)
        #expect(StackNestApp.resolveLanguage(preferredLocalizations: ["ja"]) == .ja)
        #expect(StackNestApp.resolveLanguage(preferredLocalizations: []) == .en)
    }

    @Test("バンドルは ja と en の両方を持つ")
    func bundleHasBothLocalizations() {
        let locs = Set(Bundle.main.localizations)
        #expect(locs.isSuperset(of: ["ja", "en"]), "\(locs)")
    }
}
