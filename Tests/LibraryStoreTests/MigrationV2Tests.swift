// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore

@Suite("Schema migration v2")
struct MigrationV2Tests {
    @Test("After v8 migration, thumbnails_directory_path column is dropped")
    func v8DropsV2Column() throws {
        let db = try Database.openInMemory()
        try db.migrate()

        let columns = try db.fetchImportMetaColumnNames()
        #expect(!columns.contains("thumbnails_directory_path"))
    }

    @Test("Migration is idempotent — running migrate twice does not error")
    func migrationIsIdempotent() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.migrate()  // should not throw
        let columns = try db.fetchImportMetaColumnNames()
        #expect(!columns.contains("thumbnails_directory_path"))
    }
}
