// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings.filenameFormat")
struct LibrarySettingsFormatTests {

    private func makeFreshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("libsettings_fmt_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: dbURL, mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test
    func loadsDefaultFromMigration() throws {
        let db = try makeFreshDB()
        let settings = try LibrarySettings(database: db)
        #expect(settings.filenameFormat == "(@genre) [@keywordB] [@author] @title")
    }

    @Test
    func persistsAndReloads() throws {
        let db = try makeFreshDB()
        let settings = try LibrarySettings(database: db)
        settings.filenameFormat = "@author - @title"
        let reloaded = try LibrarySettings(database: db)
        #expect(reloaded.filenameFormat == "@author - @title")
    }
}
