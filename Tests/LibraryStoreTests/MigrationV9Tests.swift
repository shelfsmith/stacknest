// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

@Suite("Migration V9: filename_format seed")
struct MigrationV9Tests {
    @Test
    func newBundleHasDefaultFilenameFormat() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v9_new_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: dbURL, mode: .createOrReplace)
        try db.migrate()

        let value = try db.getLibrarySetting(key: "filename_format")
        #expect(value == "(@genre) [@keywordB] [@author] @title")
    }

    @Test
    func doubleApplyDoesNotDuplicate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v9_double_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: dbURL, mode: .createOrReplace)
        try db.migrate()
        // Second apply should be a no-op (INSERT OR IGNORE)
        try db.migrate()

        // Should still resolve to single key, default unchanged
        let value = try db.getLibrarySetting(key: "filename_format")
        #expect(value == "(@genre) [@keywordB] [@author] @title")
    }

    @Test
    func userOverrideSurvivesReMigration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v9_override_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: dbURL, mode: .createOrReplace)
        try db.migrate()
        try db.setLibrarySetting(key: "filename_format", value: "@author - @title")
        try db.migrate()  // re-apply, must not overwrite user's value

        let value = try db.getLibrarySetting(key: "filename_format")
        #expect(value == "@author - @title")
    }
}
