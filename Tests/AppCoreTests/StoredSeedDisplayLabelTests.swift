// SPDX-License-Identifier: MIT
import Testing
import Foundation
import StackNestL10n
@testable import AppCore

/// G55 U6: 保存値（`@type` の正準ラベル・グラントの既定ラベル・既定プリセット名）は言語で変わらず、
/// 画面表示用のヘルパだけが訳すことを固定する。
@Suite("保存値は言語で変わらず、表示だけ訳す（G55 U6）")
struct StoredSeedDisplayLabelTests {
    @Test("BookTypeLabel: canonicalLabel は言語非依存、displayLabel は訳す")
    func bookTypeLabel() async {
        let jaCanon = L10nLang.$requestOverride.withValue(.ja) { (0...5).map(BookTypeLabel.canonicalLabel(for:)) }
        let enCanon = L10nLang.$requestOverride.withValue(.en) { (0...5).map(BookTypeLabel.canonicalLabel(for:)) }
        #expect(jaCanon == enCanon)
        #expect(enCanon == ["厚い本", "薄い本", "本の一部", "画像セット", "テキスト", "ムービー"])
        let enAll = L10nLang.$requestOverride.withValue(.en) { BookTypeLabel.canonicalLabels }
        #expect(enAll == BookTypeLabel.canonicalLabels)

        let jaDisp = L10nLang.$requestOverride.withValue(.ja) { (0...5).map(BookTypeLabel.displayLabel(for:)) }
        let enDisp = L10nLang.$requestOverride.withValue(.en) { (0...5).map(BookTypeLabel.displayLabel(for:)) }
        #expect(jaDisp == jaCanon)
        #expect(enDisp == ["Thick Book", "Thin Book", "Part of Book", "Image Set", "Text", "Movie"])
        #expect(L10nLang.$requestOverride.withValue(.en) { BookTypeLabel.displayLabel(for: 99) } == "")
    }

    @Test("GrantStore.displayLabel: 既定ラベルだけ訳し、利用者の名前はそのまま")
    func grantLabels() {
        L10nLang.$requestOverride.withValue(.en) {
            #expect(GrantStore.displayLabel(for: "(既定) 閲覧") == "(Default) View")
            #expect(GrantStore.displayLabel(for: "(既定) 編集") == "(Default) Edit")
            #expect(GrantStore.displayLabel(for: "家族の iPad") == "家族の iPad")
            #expect(GrantStore.displayLabel(for: "閲覧") == "閲覧")
        }
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(GrantStore.displayLabel(for: "(既定) 閲覧") == "(既定) 閲覧")
            #expect(GrantStore.displayLabel(for: "(既定) 編集") == "(既定) 編集")
            #expect(GrantStore.displayLabel(for: "家族の iPad") == "家族の iPad")
        }
    }

    @Test("GrantStore の種まきは言語に依らず日本語の既定ラベルを保存する")
    func grantSeedStoredVerbatim() throws {
        let suite = "G55-grant-seed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        L10nLang.$requestOverride.withValue(.en) {
            GrantStore.migrateIfNeeded(readToken: "R", editToken: "W", defaults: defaults)
        }
        let grants = GrantStore.list(defaults: defaults)
        #expect(grants.map(\.label) == ["(既定) 閲覧", "(既定) 編集"])
        #expect(L10nLang.$requestOverride.withValue(.en) { grants.map(\.displayLabel) } == ["(Default) View", "(Default) Edit"])
    }

    @Test("FilenameFormatPreset: 既定名だけ表示で訳し、保存値は変えない")
    func presetName() {
        let seeded = L10nLang.$requestOverride.withValue(.en) {
            FilenameFormatPresetLogic.migrate(existingFormat: "@title", id: "p1").presets[0]
        }
        #expect(seeded.name == "既定")
        L10nLang.$requestOverride.withValue(.en) {
            #expect(seeded.displayName == "Default")
            #expect(FilenameFormatPreset(id: "x", name: "作者別", format: "@author").displayName == "作者別")
            #expect(FilenameFormatPreset(id: "y", name: "  ", format: "@title").displayName == "@title")
        }
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(seeded.displayName == "既定")
            #expect(FilenameFormatPreset(id: "x", name: "作者別", format: "@author").displayName == "作者別")
        }
    }
}
