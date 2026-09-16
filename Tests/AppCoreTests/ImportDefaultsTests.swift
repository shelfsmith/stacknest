// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ImportDefaults")
struct ImportDefaultsTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "import-defaults-\(UUID().uuidString)")! }
    @Test func globalDefaults() {
        let d = suite()
        #expect(ImportDefaults.globalAutoClassify(defaults: d) == true)
        #expect(ImportDefaults.globalThickThreshold(defaults: d) == 20)
        ImportDefaults.setGlobalAutoClassify(false, defaults: d)
        ImportDefaults.setGlobalThickThreshold(40, defaults: d)
        #expect(ImportDefaults.globalAutoClassify(defaults: d) == false)
        #expect(ImportDefaults.globalThickThreshold(defaults: d) == 40)
    }
    @Test func effectivePrefersOverride() {
        let d = suite()
        ImportDefaults.setGlobalAutoClassify(true, defaults: d); ImportDefaults.setGlobalThickThreshold(20, defaults: d)
        #expect(ImportDefaults.effectiveAutoClassify(override: false, defaults: d) == false)
        #expect(ImportDefaults.effectiveAutoClassify(override: nil, defaults: d) == true)
        #expect(ImportDefaults.effectiveThickThreshold(override: 50, defaults: d) == 50)
        #expect(ImportDefaults.effectiveThickThreshold(override: nil, defaults: d) == 20)
    }
    @Test func thresholdClamped() {
        let d = suite(); ImportDefaults.setGlobalThickThreshold(999, defaults: d)
        #expect(ImportDefaults.globalThickThreshold(defaults: d) == 100)
    }

    @Test("G54-S4: EPUB の題名を使う設定の既定は false")
    func preferEPUBTitleDefaultsToFalse() {
        let suite = UserDefaults(suiteName: "g54s4-\(UUID().uuidString)")!
        #expect(ImportDefaults.globalPreferEPUBTitle(defaults: suite) == false)
    }

    @Test("G54-S4: 全体の設定が永続化される")
    func preferEPUBTitlePersists() {
        let suite = UserDefaults(suiteName: "g54s4-persist-\(UUID().uuidString)")!
        ImportDefaults.setGlobalPreferEPUBTitle(true, defaults: suite)
        #expect(ImportDefaults.globalPreferEPUBTitle(defaults: suite) == true)
        ImportDefaults.setGlobalPreferEPUBTitle(false, defaults: suite)
        #expect(ImportDefaults.globalPreferEPUBTitle(defaults: suite) == false)
    }

    @Test("G54-S4: 庫ごとの上書きが全体より優先される")
    func preferEPUBTitleOverrideWins() {
        let suite = UserDefaults(suiteName: "g54s4-override-\(UUID().uuidString)")!
        ImportDefaults.setGlobalPreferEPUBTitle(false, defaults: suite)
        #expect(ImportDefaults.effectivePreferEPUBTitle(override: true, defaults: suite) == true)
        #expect(ImportDefaults.effectivePreferEPUBTitle(override: nil, defaults: suite) == false)
    }
}
