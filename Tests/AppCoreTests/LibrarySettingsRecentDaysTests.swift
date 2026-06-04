// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings.recentDays")
struct LibrarySettingsRecentDaysTests {
    private func makeFreshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recentdays_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test
    func defaultIs14() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(s.recentDays == 14)
    }

    @Test
    func persistsAndReloads() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        s.recentDays = 30
        let r = try LibrarySettings(database: db)
        #expect(r.recentDays == 30)
    }
}
