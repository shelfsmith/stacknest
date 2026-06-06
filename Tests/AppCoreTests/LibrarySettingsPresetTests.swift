// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings filename format presets")
struct LibrarySettingsPresetTests {
    private func makeFreshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("libsettings_preset_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test func migratesLegacySingleFormatToOnePreset() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(s.filenameFormatPresets.count == 1)
        #expect(s.filenameFormatPresets[0].name == "既定")
        #expect(s.filenameFormatPresets[0].format == s.filenameFormat)
        #expect(s.defaultFilenameFormatPresetID == s.filenameFormatPresets[0].id)
        let r = try LibrarySettings(database: db)
        #expect(r.filenameFormatPresets == s.filenameFormatPresets)
        #expect(r.defaultFilenameFormatPresetID == s.defaultFilenameFormatPresetID)
    }

    @Test func addSetDefaultSyncsFilenameFormatAndPersists() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        let p = FilenameFormatPreset(id: "new1", name: "作者-タイトル", format: "@author - @title")
        s.upsertPreset(p)
        s.setDefaultPreset(id: "new1")
        #expect(s.filenameFormat == "@author - @title")
        let r = try LibrarySettings(database: db)
        #expect(r.defaultFilenameFormatPresetID == "new1")
        #expect(r.filenameFormat == "@author - @title")
        #expect(r.filenameFormatPresets.contains(p))
    }

    @Test func removeDefaultReassignsAndLastIsKept() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        let firstID = s.filenameFormatPresets[0].id
        s.upsertPreset(FilenameFormatPreset(id: "p2", name: "b", format: "@title"))
        s.setDefaultPreset(id: firstID)
        s.removePreset(id: firstID)
        #expect(s.defaultFilenameFormatPresetID == "p2")
        #expect(s.filenameFormat == "@title")
        s.removePreset(id: "p2")
        #expect(s.filenameFormatPresets.count == 1)
    }
}
