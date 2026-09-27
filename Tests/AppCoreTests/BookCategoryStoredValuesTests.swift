// SPDX-License-Identifier: MIT
import Testing
import StackNestL10n
@testable import AppCore

@Suite("本の種類の保存値は言語で変わらない（G55）")
struct BookCategoryStoredValuesTests {
    @Test("表示名は言語で変わるが、保存値（rawValue 等）は同じ")
    func storedValuesAreLanguageIndependent() async {
        let ja = await L10nLang.$requestOverride.withValue(.ja) { BookCategory.allCases.map(\.rawValue) }
        let en = await L10nLang.$requestOverride.withValue(.en) { BookCategory.allCases.map(\.rawValue) }
        #expect(ja == en)
    }
}
