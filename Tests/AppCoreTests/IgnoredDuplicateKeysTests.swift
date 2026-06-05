// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings.ignoredDuplicateKeys")
struct IgnoredDuplicateKeysTests {
    private func freshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("igndup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test func defaultsEmpty() throws {
        let s = try LibrarySettings(database: try freshDB())
        #expect(s.ignoredDuplicateKeys.isEmpty)
    }

    @Test func persistsAndReloads() throws {
        let db = try freshDB()
        let s = try LibrarySettings(database: db)
        s.ignoredDuplicateKeys = ["exact:abc", "possible:S\u{0}1"]
        let r = try LibrarySettings(database: db)
        #expect(r.ignoredDuplicateKeys == ["exact:abc", "possible:S\u{0}1"])
    }
}
