// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
import StackroomFormat

@Suite("NFC backfill + insert normalization")
struct NFCBackfillTests {
    private func freshDB() throws -> Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nfc_\(UUID().uuidString).sqlite")
        let db = try Database.openFile(at: url, mode: .createOrReplace)
        try db.migrate()
        return db
    }

    // MARK: - insertBookReturningID normalizes text fields

    @Test func insertNormalizesSeriesAndTitleToNFC() throws {
        let db = try freshDB()
        // NFD "ブリーズ": フ(U+30D5) + combining dakuten(U+3099) + リーズ
        let nfd = "\u{30D5}\u{3099}リーズ"
        let book = BookRecord(
            id: 1,
            title: nfd,
            path: "/x",
            dateAdded: Date(timeIntervalSince1970: 0),
            series: nfd
        )
        let id = try db.insertBookReturningID(book)
        let fetched = try db.fetchBook(id: id)!
        let nfc = nfd.precomposedStringWithCanonicalMapping
        // Title must be stored as precomposed NFC (byte-level check).
        #expect(Array(fetched.title.utf8) == Array(nfc.utf8))
        // Series must be stored as precomposed NFC.
        #expect(fetched.series != nil)
        #expect(Array(fetched.series!.utf8) == Array(nfc.utf8))
    }

    // MARK: - backfill normalizes pre-existing NFD rows

    @Test func backfillNormalizesExistingRows() throws {
        let db = try freshDB()
        // Insert raw NFD data bypassing the NFC normalization in insertBook.
        let nfd = "\u{30D5}\u{3099}"   // decomposed ブ (2 scalars, 6 UTF-8 bytes)
        let nfc = nfd.precomposedStringWithCanonicalMapping  // precomposed ブ (1 scalar, 3 bytes)
        try db.rawExecuteForTest(
            "INSERT INTO book (title, path, date_added, book_type, file_type, rating, unseen, series) VALUES (?, '/x', 0, 0, 0, 0, 1, ?)",
            [nfd, nfd]
        )
        // Verify the raw row is actually NFD (byte-level check).
        let books = try db.fetchAllBooks()
        let before = books.first(where: { $0.series != nil })!
        #expect(Array(before.series!.utf8) == Array(nfd.utf8))

        // Run the backfill.
        try db.runNFCBackfillForTest()

        // All text columns must now be NFC.
        let after = try db.fetchAllBooks()
        #expect(after.allSatisfy {
            Array($0.title.utf8) == Array($0.title.precomposedStringWithCanonicalMapping.utf8)
        })
        #expect(after.contains {
            $0.series != nil && Array($0.series!.utf8) == Array(nfc.utf8)
        })
    }

    // MARK: - migration v16 flag gates the backfill to one run

    @Test func migrationV16IsIdempotent() throws {
        let db = try freshDB()
        // migrate() already ran v16 once; running it again must not fail.
        try db.migrate()
        // The flag must be set in library_settings.
        let flag = try db.read { grdbDB in
            try String.fetchOne(grdbDB, sql: "SELECT value FROM library_settings WHERE key = 'nfc_normalized_v1'")
        }
        #expect(flag == "1")
    }
}
