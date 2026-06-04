// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore
import StackroomFormat

@Suite("Migration + insertBook")
struct MigrationInsertBookTests {
    @Test("Migrate creates book table and insertBook stores all fields")
    func migrateAndInsert() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let added = Date(timeIntervalSince1970: 1735689600)
        let played = Date(timeIntervalSince1970: 1745930096)
        let book = BookRecord(
            id: 42,
            title: "Hello",
            author: "Author1",
            genre: "g",
            coverImagePath: "/c",
            coverImageName: nil,
            dateAdded: added,
            playDate: played,
            bookType: 1,
            fileType: 2,
            pages: 100,
            myRate: 3,
            unseen: false,
            keywordA: "alpha",
            keywordB: "beta",
            keywordC: "gamma",
            neta: "spoiler"
        )
        try db.insertBook(book)

        let count = try db.fetchBookCount()
        #expect(count == 1)
        let row = try db.fetchFirstBookRow()
        #expect(row?.title == "Hello")
        #expect(row?.author == "Author1")
        #expect(row?.dateAdded == added)
        #expect(row?.playDate == played)
        #expect(row?.bookType == 1)
        #expect(row?.fileType == 2)
        #expect(row?.pages == 100)
        #expect(row?.rating == 3)
        #expect(row?.unseen == false)
        #expect(row?.keywordA == "alpha")
        #expect(row?.keywordB == "beta")
        #expect(row?.keywordC == "gamma")
        #expect(row?.neta == "spoiler")
        db.close()
    }
}
