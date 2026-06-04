// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings custom labels — persist/load")
struct LibrarySettingsLabelTests {
    private func makeFreshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("libsettings_label_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test func defaultsEmpty() throws {
        let s = try LibrarySettings(database: try makeFreshDB())
        #expect(s.customFieldLabels.isEmpty)
        #expect(s.customBookTypeLabels.isEmpty)
    }

    @Test func persistsAndReloads() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        s.customFieldLabels = ["keyword_a": "作画", "genre": "サークル"]
        s.customBookTypeLabels = ["0": "長編", "1": "短編"]
        let r = try LibrarySettings(database: db)
        #expect(r.customFieldLabels == ["keyword_a": "作画", "genre": "サークル"])
        #expect(r.customBookTypeLabels == ["0": "長編", "1": "短編"])
    }

    @Test func emptyValuesAreStrippedOnPersist() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        s.customFieldLabels = ["keyword_a": "作画", "genre": ""]
        let r = try LibrarySettings(database: db)
        #expect(r.customFieldLabels == ["keyword_a": "作画"])
        #expect(r.customFieldLabels["genre"] == nil)
    }
}
