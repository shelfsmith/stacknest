// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore
import StackroomFormat

@Suite("Migration v3 - playlist.kind column")
struct MigrationV3Tests {
    @Test func freshDBHasKindColumn() throws {
        let db = try Database.openInMemory()
        try db.migrate()

        let columns = try db.fetchPlaylistColumnNames()
        #expect(columns.contains("kind"))
    }

    @Test func existingPlaylistRowsDefaultToImported() throws {
        let db = try Database.openInMemory()
        try db.migrate()

        // Insert a playlist via existing API (no kind specified)
        let playlist = PlaylistRecord(title: "Test", type: 0, items: [])
        try db.insertPlaylist(playlist)

        let kinds = try db.fetchAllPlaylistKinds()
        #expect(kinds == ["imported"])
    }

    @Test func migrationIsIdempotent() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.migrate()  // run twice, should not throw or duplicate column
        try db.migrate()

        let columns = try db.fetchPlaylistColumnNames()
        let kindCount = columns.filter { $0 == "kind" }.count
        #expect(kindCount == 1)
    }
}
