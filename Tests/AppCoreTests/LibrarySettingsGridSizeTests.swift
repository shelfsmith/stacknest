// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings.gridItemSize")
struct LibrarySettingsGridSizeTests {
    private func makeFreshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gridsize_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test
    func defaultIs160() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(s.gridItemSize == 160)
    }

    @Test
    func persistsAndReloads() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        s.gridItemSize = 220
        let r = try LibrarySettings(database: db)
        #expect(r.gridItemSize == 220)
    }
}
