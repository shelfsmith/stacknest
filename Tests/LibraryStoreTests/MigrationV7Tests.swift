// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

@Suite("Migration v7 - FTS5 rebuild with trigram tokenizer")
struct MigrationV7Tests {
    @Test func ftsCreateSqlContainsTrigram() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let createSQL = try db.fetchFTSCreateSQL()
        #expect(createSQL.contains("trigram"))
    }

    @Test func substringSearchHitsAfterMigration() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.insertBook(BookRow.testInstance(id: 1, title: "ハイスコアガール DASH 第08巻"))
        let r1 = try db.searchBooks(query: "スコア", sidebarScope: .library)
        #expect(r1.map(\.id) == [1])
        let r2 = try db.searchBooks(query: "ガール", sidebarScope: .library)
        #expect(r2.map(\.id) == [1])
        let r3 = try db.searchBooks(query: "ASH", sidebarScope: .library)
        #expect(r3.map(\.id) == [1])
        let r4 = try db.searchBooks(query: "08巻", sidebarScope: .library)
        #expect(r4.map(\.id) == [1])
    }

    @Test func migrationIsIdempotent() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.migrate()
        try db.migrate()
        let createSQL = try db.fetchFTSCreateSQL()
        #expect(createSQL.contains("trigram"))
        let count = try db.fetchFTSTableCount()
        #expect(count == 1)
    }

    @Test func ftsColumnsUnchanged() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let cols = try db.fetchFTSColumns()
        #expect(cols.contains("title"))
        #expect(cols.contains("author"))
        #expect(cols.contains("genre"))
        #expect(cols.contains("keyword_a"))
        #expect(cols.contains("keyword_b"))
        #expect(cols.contains("neta"))
        #expect(cols.contains("memo"))
        #expect(cols.contains("cover_name") == false)
    }
}
