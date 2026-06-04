// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings.libraryUUID")
struct LibrarySettingsLibraryUUIDTests {
    private func makeFreshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("libsettings_uuid_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: dbURL, mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test
    func libraryUUIDIsNilByDefault() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(s.libraryUUID == nil)
    }

    @Test
    func ensureGeneratesAndPersists() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        let uuid = s.ensureLibraryUUID()
        #expect(!uuid.isEmpty)
        #expect(s.libraryUUID == uuid)
        let r = try LibrarySettings(database: db)
        #expect(r.libraryUUID == uuid)
    }

    @Test
    func ensureIsIdempotent() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        let uuid1 = s.ensureLibraryUUID()
        let uuid2 = s.ensureLibraryUUID()
        #expect(uuid1 == uuid2)
    }
}
