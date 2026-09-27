// SPDX-License-Identifier: MIT
import Testing
import StackNestL10n
@testable import AppCore

@Suite("G56-S1: 既定名の編集欄（表示名で見せ、保存値を守る）")
struct SeededNameEditingTests {
    private let presetDisplay: (String) -> String = { FilenameFormatPreset.displayName(forStoredName: $0) }
    private let grantDisplay: (String) -> String = { GrantStore.displayLabel(for: $0) }

    @Test func englishShowsDisplayNameAndKeepsStoredValue() {
        L10nLang.$requestOverride.withValue(.en) {
            #expect(SeededNameEditing.fieldText(stored: "既定", display: presetDisplay) == "Default")
            // 開いて閉じただけ（欄は表示名のまま）→ 保存値は日本語の種のまま
            #expect(SeededNameEditing.storedValue(field: "Default", original: "既定", display: presetDisplay) == "既定")
            #expect(SeededNameEditing.storedValue(field: "(Default) View", original: "(既定) 閲覧", display: grantDisplay) == "(既定) 閲覧")
            // 書き換えたら書き換えた値
            #expect(SeededNameEditing.storedValue(field: "Mine", original: "既定", display: presetDisplay) == "Mine")
        }
    }

    @Test func japaneseIsIdentity() {
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(SeededNameEditing.fieldText(stored: "既定", display: presetDisplay) == "既定")
            #expect(SeededNameEditing.storedValue(field: "既定", original: "既定", display: presetDisplay) == "既定")
        }
    }

    @Test func userNamesPassThrough() {
        L10nLang.$requestOverride.withValue(.en) {
            #expect(SeededNameEditing.fieldText(stored: "漫画用", display: presetDisplay) == "漫画用")
            #expect(SeededNameEditing.storedValue(field: "漫画用", original: "漫画用", display: presetDisplay) == "漫画用")
        }
    }
}
