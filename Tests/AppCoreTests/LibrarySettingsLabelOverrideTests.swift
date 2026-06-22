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

    /// 4.2c-8: reloadCustomLabels は DB の外部変更（リモート PUT 相当）をメモリへ反映する。
    @Test func reloadCustomLabelsPicksUpExternalDBChange() throws {
        let db = try Database.openInMemory(); try db.migrate()
        let s = try LibrarySettings(database: db)
        #expect(s.label(for: .keywordC) == BookColumn.keywordC.localizedTitleString)  // 正準
        // 外部（リモート PUT 相当）が DB を直接書き換える。
        try db.setLibrarySetting(key: "custom_field_labels", value: #"{"keyword_c":"外部名"}"#)
        s.reloadCustomLabels()
        #expect(s.label(for: .keywordC) == "外部名")
        // 空に戻す書き換えも反映される。
        try db.setLibrarySetting(key: "custom_field_labels", value: "{}")
        s.reloadCustomLabels()
        #expect(s.label(for: .keywordC) == BookColumn.keywordC.localizedTitleString)
    }
}
