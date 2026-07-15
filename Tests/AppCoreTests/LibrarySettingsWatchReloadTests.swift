// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings watch reload (G12b-2c A2)")
struct LibrarySettingsWatchReloadTests {
    /// G12b-2c A2: reloadWatchedFolders は DB の外部変更（リモートの watch-config PUT 相当）を
    /// メモリへ反映する（ホストの FolderWatcher をライブ再構成するため）。
    @Test func reloadWatchedFoldersPicksUpExternalDBChange() throws {
        let db = try Database.openInMemory(); try db.migrate()
        let s = try LibrarySettings(database: db)
        #expect(s.folderWatchEnabled == false)
        #expect(s.watchedFolders.isEmpty)

        // 外部（リモートの watch-config PUT 相当）が DB を直接書き換える。
        try db.setLibrarySetting(key: "folder_watch_enabled", value: "true")
        let folders = [WatchedFolder(id: "f1", path: "/tmp/x", enabled: true, subfolderMode: .recurse)]
        let data = try JSONEncoder().encode(folders)
        try db.setLibrarySetting(key: "watched_folders", value: String(decoding: data, as: UTF8.self))

        s.reloadWatchedFolders()
        #expect(s.folderWatchEnabled == true)
        #expect(s.watchedFolders.count == 1)
        #expect(s.watchedFolders.first?.id == "f1")
        #expect(s.watchedFolders.first?.subfolderMode == .recurse)
    }
}
