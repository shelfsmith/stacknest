// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("MigrationV8")
struct MigrationV8Tests {

    /// Builds a temp DB with v1 base schema + v2-v7 migrations applied,
    /// stopping just before v8. Replicates the pre-v8 column shape.
    private func makePreV8DB() throws -> Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("v8-test-\(UUID().uuidString).sqlite")
        let db = try Database.openFile(at: url, mode: .createOrReplace)
        // Manually create pre-v8 schema instead of using openFile to avoid type ambiguity
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS book (
                    id INTEGER PRIMARY KEY, title TEXT NOT NULL, author TEXT, genre TEXT,
                    path TEXT, cover_path TEXT NOT NULL DEFAULT '', cover_name TEXT,
                    date_added REAL NOT NULL, play_date REAL,
                    book_type INTEGER NOT NULL DEFAULT 0, file_type INTEGER NOT NULL DEFAULT 0,
                    pages INTEGER, rating INTEGER NOT NULL DEFAULT 0,
                    unseen INTEGER NOT NULL DEFAULT 1,
                    keyword_a TEXT, keyword_b TEXT, keyword_c TEXT, neta TEXT, memo TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS import_meta (
                    schema_version INTEGER NOT NULL, imported_at REAL NOT NULL,
                    source_xml_path TEXT NOT NULL, source_xml_mtime REAL NOT NULL,
                    importer_version TEXT NOT NULL, book_count INTEGER NOT NULL,
                    skipped_count INTEGER NOT NULL, notes TEXT,
                    thumbnails_directory_path TEXT
                )
                """)
        }
        return db
    }

    @Test("v8 drops cover_path and cover_name from book")
    func dropsBookCoverColumns() throws {
        let db = try makePreV8DB()
        try db.migrate()  // applies v1..v8
        let names = try db.fetchTableColumnNames(tableName: "book")
        #expect(!names.contains("cover_path"))
        #expect(!names.contains("cover_name"))
        #expect(names.contains("title"))  // sanity
    }

    @Test("v8 drops thumbnails_directory_path from import_meta")
    func dropsThumbnailsDirColumn() throws {
        let db = try makePreV8DB()
        try db.migrate()
        let names = try db.fetchTableColumnNames(tableName: "import_meta")
        #expect(!names.contains("thumbnails_directory_path"))
    }

    @Test("v8 is idempotent — second migrate does not throw")
    func idempotent() throws {
        let db = try makePreV8DB()
        try db.migrate()
        // Second run should be no-op
        try db.migrate()
    }
}
