// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryStore
@testable import AppCore

@Suite("FilenameFormatResolver")
struct FilenameFormatResolverTests {
    private func makeDB() throws -> Database {
        let db = try Database.openInMemory(); try db.migrate(); return db
    }
    @Test func fallsBackToDefaultFormat() throws {
        let db = try makeDB()
        try db.setLibrarySetting(key: "filename_format", value: "[@author] @title")
        #expect(FilenameFormatResolver.resolveRaw(database: db, presetID: nil) == "[@author] @title")
        #expect(FilenameFormatResolver.resolveRaw(database: db, presetID: "missing") == "[@author] @title")
    }
    @Test func resolvesPresetFormat() throws {
        let db = try makeDB()
        try db.setLibrarySetting(key: "filename_format", value: "@title")
        let presets = [FilenameFormatPreset(id: "p1", name: "DL", format: "@series @volume")]
        try db.setLibrarySetting(key: "filename_format_presets",
                                 value: String(data: JSONEncoder().encode(presets), encoding: .utf8)!)
        #expect(FilenameFormatResolver.resolveRaw(database: db, presetID: "p1") == "@series @volume")
    }
}
