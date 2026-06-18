// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import LibraryStore

@Suite("LibrarySettings displayName")
struct LibraryDisplayNameTests {
    private func db() throws -> Database { let d = try Database.openInMemory(); try d.migrate(); return d }

    @Test @MainActor func defaultEmptyThenPersists() throws {
        let database = try db()
        let s = try LibrarySettings(database: database)
        #expect(s.displayName == "")
        s.displayName = "My Comics"
        let s2 = try LibrarySettings(database: database)
        #expect(s2.displayName == "My Comics")
    }

    @Test @MainActor func resolvedNameFallsBackToFilename() throws {
        let s = try LibrarySettings(database: db())
        #expect(s.resolvedName(fallback: "bundleA") == "bundleA")
        s.displayName = "Rich Name"
        #expect(s.resolvedName(fallback: "bundleA") == "Rich Name")
        s.displayName = "   "
        #expect(s.resolvedName(fallback: "bundleA") == "bundleA")
    }
}
