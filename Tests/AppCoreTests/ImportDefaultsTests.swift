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
}
