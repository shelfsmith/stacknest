// SPDX-License-Identifier: MIT
import Testing
import LibraryStore
@testable import AppCore

@Suite("LibrarySettings backup options")
@MainActor
struct LibrarySettingsBackupTests {
    private func freshSettings() throws -> (Database, LibrarySettings) {
        let db = try Database.openInMemory()
        try db.migrate()
        return (db, try LibrarySettings(database: db))
    }

    @Test func defaultsAreEnabledAndFiveGenerations() throws {
        let (_, s) = try freshSettings()
        #expect(s.backupEnabled == true)
        #expect(s.backupGenerations == 5)
    }

    @Test func changesPersistAcrossReload() throws {
        let (db, s) = try freshSettings()
        s.backupEnabled = false
        s.backupGenerations = 12
        let reloaded = try LibrarySettings(database: db)
        #expect(reloaded.backupEnabled == false)
        #expect(reloaded.backupGenerations == 12)
    }
}
