// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings.topPaneMode")
struct LibrarySettingsTopPaneModeTests {
    private func makeFreshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topmode_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test
    func defaultIsBrowse() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(s.topPaneMode == "browse")
    }

    @Test
    func persistsAndReloads() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        s.topPaneMode = "stamp"
        let r = try LibrarySettings(database: db)
        #expect(r.topPaneMode == "stamp")
    }

    @Test
    func hiddenAlsoPersists() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        s.topPaneMode = "hidden"
        let r = try LibrarySettings(database: db)
        #expect(r.topPaneMode == "hidden")
    }
}
