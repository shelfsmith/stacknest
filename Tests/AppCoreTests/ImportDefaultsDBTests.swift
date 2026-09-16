// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryStore
@testable import AppCore

@Suite("ImportDefaults db resolution")
struct ImportDefaultsDBTests {
    private func db() throws -> Database { let d = try Database.openInMemory(); try d.migrate(); return d }
    private func suite() -> UserDefaults { UserDefaults(suiteName: "importdef-\(UUID().uuidString)")! }

    @Test func overrideAbsentUsesGlobal() throws {
        let d = try db(); let u = suite()
        ImportDefaults.setGlobalAutoClassify(true, defaults: u)
        ImportDefaults.setGlobalThickThreshold(30, defaults: u)
        #expect(ImportDefaults.autoClassifyOverride(db: d) == nil)
        #expect(ImportDefaults.effectiveAutoClassify(db: d, defaults: u) == true)
        #expect(ImportDefaults.effectiveThickThreshold(db: d, defaults: u) == 30)
    }
    @Test func overridePresentWins() throws {
        let d = try db(); let u = suite()
        ImportDefaults.setGlobalAutoClassify(true, defaults: u)
        try d.setLibrarySetting(key: ImportDefaults.libAutoClassifyKey, value: "false")
        try d.setLibrarySetting(key: ImportDefaults.libThickThresholdKey, value: "50")
        #expect(ImportDefaults.autoClassifyOverride(db: d) == false)
        #expect(ImportDefaults.thickThresholdOverride(db: d) == 50)
        #expect(ImportDefaults.effectiveAutoClassify(db: d, defaults: u) == false)
        #expect(ImportDefaults.effectiveThickThreshold(db: d, defaults: u) == 50)
    }
    @Test func overrideTrueAndOneParsed() throws {
        let d = try db()
        try d.setLibrarySetting(key: ImportDefaults.libAutoClassifyKey, value: "1")
        #expect(ImportDefaults.autoClassifyOverride(db: d) == true)
        try d.setLibrarySetting(key: ImportDefaults.libAutoClassifyKey, value: "true")
        #expect(ImportDefaults.autoClassifyOverride(db: d) == true)
    }
    @Test func invalidThresholdIsNil() throws {
        let d = try db()
        try d.setLibrarySetting(key: ImportDefaults.libThickThresholdKey, value: "abc")
        #expect(ImportDefaults.thickThresholdOverride(db: d) == nil)
    }

    @Test("G54-S4: override が無ければグローバル既定（false）を使う")
    func preferEPUBTitleOverrideAbsentUsesGlobal() throws {
        let d = try db(); let u = suite()
        ImportDefaults.setGlobalPreferEPUBTitle(true, defaults: u)
        #expect(ImportDefaults.preferEPUBTitleOverride(db: d) == nil)
        #expect(ImportDefaults.effectivePreferEPUBTitle(db: d, defaults: u) == true)
    }

    @Test("G54-S4: 庫ごとの override が全体設定より優先される")
    func preferEPUBTitleOverridePresentWins() throws {
        let d = try db(); let u = suite()
        ImportDefaults.setGlobalPreferEPUBTitle(false, defaults: u)
        try d.setLibrarySetting(key: ImportDefaults.libPreferEPUBTitleKey, value: "true")
        #expect(ImportDefaults.preferEPUBTitleOverride(db: d) == true)
        #expect(ImportDefaults.effectivePreferEPUBTitle(db: d, defaults: u) == true)
    }

    @Test("G54-S4: override の \"1\" も真として解釈される")
    func preferEPUBTitleOverrideOneParsed() throws {
        let d = try db()
        try d.setLibrarySetting(key: ImportDefaults.libPreferEPUBTitleKey, value: "1")
        #expect(ImportDefaults.preferEPUBTitleOverride(db: d) == true)
    }
}
