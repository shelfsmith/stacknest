// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings lock fields")
struct LibrarySettingsLockTests {
    private func makeFreshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("libsettings_lock_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: dbURL, mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test
    func defaultsAreNoPassword() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(s.lockPasswordHash == nil)
        #expect(s.lockPasswordSalt == nil)
        #expect(s.useBiometric == false)
    }

    @Test
    func persistsAndReloadsHashSaltBiometric() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        try s.setLock(hash: "deadbeef", salt: "cafebabe")
        s.useBiometric = true
        let r = try LibrarySettings(database: db)
        #expect(r.lockPasswordHash == "deadbeef")
        #expect(r.lockPasswordSalt == "cafebabe")
        #expect(r.useBiometric == true)
    }

    @Test
    func clearingHashRemovesAllLockData() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        try s.setLock(hash: "deadbeef", salt: "cafebabe")
        s.useBiometric = true
        try s.clearLock()
        s.useBiometric = false
        let r = try LibrarySettings(database: db)
        #expect(r.lockPasswordHash == nil)
        #expect(r.lockPasswordSalt == nil)
        #expect(r.useBiometric == false)
    }
}
