// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryStore
@testable import AppCore

@MainActor
@Suite("LibrarySettings folder watch")
struct WatchedFolderSettingsTests {
    private func makeSettings() throws -> (LibrarySettings, Database) {
        let db = try Database.openInMemory()
        try db.migrate()
        let s = try LibrarySettings(database: db)
        return (s, db)
    }

    @Test func defaultsAndPersistRoundTrip() throws {
        let (s, db) = try makeSettings()
        #expect(s.folderWatchEnabled == false)
        #expect(s.watchedFolders.isEmpty)
        s.folderWatchEnabled = true
        s.watchedFolders = [WatchedFolder(id: "a", path: "/tmp/dl", presetID: nil)]
        let s2 = try LibrarySettings(database: db)
        #expect(s2.folderWatchEnabled == true)
        #expect(s2.watchedFolders.count == 1)
        #expect(s2.watchedFolders.first?.path == "/tmp/dl")
    }

    @Test func resolvesFilenameFormatRawByPreset() throws {
        let (s, _) = try makeSettings()
        let p = FilenameFormatPreset(id: "p1", name: "DL", format: "[@author] @title")
        s.upsertPreset(p)
        #expect(s.resolvedFilenameFormatRaw(forPresetID: "p1") == "[@author] @title")
        #expect(s.resolvedFilenameFormatRaw(forPresetID: nil) == s.filenameFormat)
        #expect(s.resolvedFilenameFormatRaw(forPresetID: "zzz") == s.filenameFormat)
    }
}
