// SPDX-License-Identifier: MIT
import Testing
import LibraryStore
@testable import AppCore

@Suite("LibrarySettings remote sharing opt-in")
@MainActor
struct LibrarySettingsRemoteSharingTests {
    private func freshSettings() throws -> (Database, LibrarySettings) {
        let db = try Database.openInMemory()
        try db.migrate()
        return (db, try LibrarySettings(database: db))
    }

    /// 既定では per-library のリモート共有は OFF（明示オプトイン）。
    @Test func defaultsToDisabled() throws {
        let (_, s) = try freshSettings()
        #expect(s.remoteSharingEnabled == false)
    }

    /// set → persist → 再 init で読める。
    @Test func changePersistsAcrossReload() throws {
        let (db, s) = try freshSettings()
        s.remoteSharingEnabled = true
        let reloaded = try LibrarySettings(database: db)
        #expect(reloaded.remoteSharingEnabled == true)
    }
}
