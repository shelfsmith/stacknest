// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings general reload (G12b-3a)")
struct LibrarySettingsGeneralReloadTests {
    @Test func reloadGeneralSettingsPicksUpExternalDBChange() throws {
        let db = try Database.openInMemory(); try db.migrate()
        let s = try LibrarySettings(database: db)
        try db.setLibrarySetting(key: "display_name", value: "外部名")
        try db.setLibrarySetting(key: "backup_enabled", value: "true")
        try db.setLibrarySetting(key: "backup_generations", value: "9")
        s.reloadGeneralSettings()
        #expect(s.displayName == "外部名")
        #expect(s.backupEnabled == true)
        #expect(s.backupGenerations == 9)
    }
}
