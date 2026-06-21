// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings label override")
struct LibrarySettingsLabelOverrideTests {
    private func makeSettings() throws -> LibrarySettings {
        let db = try Database.openInMemory(); try db.migrate()
        return try LibrarySettings(database: db)
    }

    @Test func overrideTakesPrecedenceForStampLabel() throws {
        let s = try makeSettings()
        s.customFieldLabels = ["keyword_c": "ローカル名"]
        #expect(s.stampLabel(for: .keywordC) == "ローカル名")
        s.remoteFieldLabelOverride = ["keyword_c": "サーバ名"]
        #expect(s.stampLabel(for: .keywordC) == "サーバ名")
    }

    @Test func overrideAppliesToColumnAndBookType() throws {
        let s = try makeSettings()
        s.remoteFieldLabelOverride = ["keyword_c": "作者別名"]
        s.remoteBookTypeLabelOverride = ["0": "長編"]
        #expect(s.label(for: .keywordC) == "作者別名")
        #expect(s.bookTypeLabel(0) == "長編")
    }

    @Test func nilOverrideFallsBackToCustomThenCanonical() throws {
        let s = try makeSettings()
        #expect(s.label(for: .keywordC) == BookColumn.keywordC.localizedTitleString)  // 正準
        s.customFieldLabels = ["keyword_c": "カスタム"]
        s.remoteFieldLabelOverride = nil
        #expect(s.label(for: .keywordC) == "カスタム")
    }
}
