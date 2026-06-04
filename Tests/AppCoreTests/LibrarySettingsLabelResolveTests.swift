// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings label resolvers")
struct LibrarySettingsLabelResolveTests {
    private func makeSettings() throws -> LibrarySettings {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("libsettings_resolve_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        return try LibrarySettings(database: db)
    }

    @Test func fieldLabelDefaultsWhenNoOverride() throws {
        let s = try makeSettings()
        #expect(s.label(for: .keywordA) == BookColumn.keywordA.localizedTitleString)
        #expect(s.label(for: .title) == BookColumn.title.localizedTitleString)
    }

    @Test func fieldLabelOverrideAppliesToCustomizableOnly() throws {
        let s = try makeSettings()
        s.customFieldLabels = ["keyword_a": "作画", "title": "題名"]
        #expect(s.label(for: .keywordA) == "作画")
        #expect(s.label(for: .title) == BookColumn.title.localizedTitleString)
    }

    @Test func stampAndBrowseShareSameOverrideByDbColumn() throws {
        let s = try makeSettings()
        s.customFieldLabels = ["keyword_c": "種別"]
        #expect(s.stampLabel(for: .keywordC) == "種別")
        #expect(s.browseLabel(for: .keywordC) == "種別")
    }

    @Test func bookTypeLabelOverrideAndDefault() throws {
        let s = try makeSettings()
        #expect(s.bookTypeLabel(0) == "厚い本")
        s.customBookTypeLabels = ["0": "長編"]
        #expect(s.bookTypeLabel(0) == "長編")
        #expect(s.bookTypeLabel(1) == "薄い本")
    }

    @Test func bookTypeLabelOutOfRangeIsEmpty() throws {
        let s = try makeSettings()
        #expect(s.bookTypeLabel(99) == "")
        #expect(s.bookTypeLabel(-1) == "")
    }

    /// 対象外フィールド（series/author）は customFieldLabels に値があっても正準のまま。
    @Test func browseLabelIgnoresOverrideForStructuralFields() throws {
        let s = try makeSettings()
        s.customFieldLabels = ["series": "巻物", "author": "描き手"]
        #expect(s.browseLabel(for: .series) == "シリーズ")
        #expect(s.browseLabel(for: .author) == "作者")
    }
}
