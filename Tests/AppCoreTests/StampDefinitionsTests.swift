// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings.stampDefinitions")
struct StampDefinitionsTests {
    private func makeFreshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stampdef_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test
    func defaultIsEmpty() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(s.stampDefinitions.isEmpty)
    }

    @Test
    func persistsAndReloads() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        s.stampDefinitions = [
            "genre": ["マンガ", "小説"],
            "keyword_a": ["名作"]
        ]
        let r = try LibrarySettings(database: db)
        #expect(r.stampDefinitions["genre"] == ["マンガ", "小説"])
        #expect(r.stampDefinitions["keyword_a"] == ["名作"])
        #expect(r.stampDefinitions["neta"] == nil)
    }

    @Test
    func partialUpdate() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        s.stampDefinitions = ["genre": ["A"]]
        var defs = s.stampDefinitions
        defs["genre"]?.append("B")
        s.stampDefinitions = defs
        let r = try LibrarySettings(database: db)
        #expect(r.stampDefinitions["genre"] == ["A", "B"])
    }
}
