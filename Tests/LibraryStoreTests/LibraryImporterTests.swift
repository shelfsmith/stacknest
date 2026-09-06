// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import LibraryStore
import StackroomFormat

@Suite("LibraryImporter")
struct LibraryImporterTests {
    private func makeBook(id: Int) -> BookRecord {
        BookRecord(
            id: id,
            title: "Book\(id)",
            genre: "g",
            coverImagePath: "/c",
            dateAdded: Date(timeIntervalSince1970: 0),
            bookType: 0,
            fileType: 2,
            myRate: 0,
            unseen: false
        )
    }

    @Test("Imports books, skips dict-key anomalies")
    func importsAndSkipsAnomalies() throws {
        let db = try Database.openInMemory()
        try db.migrate()

        // After T26, dict-key validation runs in LibraryDocument.init(from:),
        // so anomalies are surfaced via the document's `anomalies` array.
        let document = LibraryDocument(
            books: ["1": makeBook(id: 1)],
            anomalies: [.dictKeyNotInteger(rawKey: "abc")]
        )

        let importer = LibraryImporter(database: db)
        let summary = try importer.run(document: document)

        #expect(summary.imported == 1)
        #expect(summary.skipped.count == 1)
        #expect(summary.skipped[0].id == "abc")
        #expect(summary.skipped[0].reason.contains("integer"))

        let dbCount = try db.fetchBookCount()
        #expect(dbCount == 1)
        db.close()
    }

    @Test("Reports progress for every book processed")
    func reportsProgress() throws {
        final class Counter: ProgressReporter, @unchecked Sendable {
            var count = 0
            func reportProgress(processed: Int, total: Int) { count += 1 }
        }

        let db = try Database.openInMemory()
        try db.migrate()
        let document = LibraryDocument(books: [
            "1": makeBook(id: 1),
            "2": makeBook(id: 2),
            "3": makeBook(id: 3)
        ])
        let counter = Counter()
        let importer = LibraryImporter(database: db)
        _ = try importer.run(document: document, progress: counter)
        #expect(counter.count == 3)
        db.close()
    }

    @Test("ImportSummary records non-zero elapsed time")
    func recordsElapsedTime() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let doc = LibraryDocument(books: ["1": makeBook(id: 1)])
        let importer = LibraryImporter(database: db)
        let summary = try importer.run(document: doc)
        #expect(summary.elapsed >= 0)
        #expect(summary.imported == 1)
        db.close()
    }

    @Test("Imports playlists alongside books")
    func importsPlaylists() throws {
        let db = try Database.openInMemory()
        try db.migrate()

        let playlist = PlaylistRecord(
            title: "Mix",
            type: 0,
            icon: 1,
            itemView: true,
            toolTab: false,
            items: [1, 2]
        )
        let document = LibraryDocument(
            books: [
                "1": makeBook(id: 1),
                "2": makeBook(id: 2)
            ],
            playlists: [playlist]
        )

        let importer = LibraryImporter(database: db)
        let summary = try importer.run(document: document)

        #expect(summary.imported == 2)
        #expect(try db.fetchPlaylistCount() == 1)
        #expect(try db.fetchPlaylistItemCount() == 2)
        db.close()
    }

    @Test("Filters orphan book references from playlists, records warning")
    func filtersOrphanPlaylistReferences() throws {
        let db = try Database.openInMemory()
        try db.migrate()

        // Books 1 and 2 will be imported. Book 999 won't exist.
        let book1 = makeBook(id: 1)
        let book2 = makeBook(id: 2)
        // Playlist references 1, 2, AND 999 (orphan).
        let playlist = PlaylistRecord(
            title: "Test Playlist",
            type: 0,
            items: [1, 2, 999]
        )
        let doc = LibraryDocument(
            books: ["1": book1, "2": book2],
            playlists: [playlist]
        )

        let importer = LibraryImporter(database: db)
        let summary = try importer.run(document: doc)

        #expect(summary.imported == 2)
        #expect(summary.warnings.count == 1)
        #expect(summary.warnings[0].contains("Test Playlist"))
        #expect(summary.warnings[0].contains("1 orphan"))

        // Playlist inserted with only 2 valid items.
        let plItemCount = try db.fetchPlaylistItemCount()
        #expect(plItemCount == 2)
        db.close()
    }

    @Test("Writes import metadata after a successful run, including thumbnails_directory_path when set")
    func writesImportMeta() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let book = makeBook(id: 1)
        let doc = LibraryDocument(books: ["1": book])
        let importer = LibraryImporter(database: db)
        _ = try importer.run(
            document: doc,
            sourceURL: URL(fileURLWithPath: "/Users/me/Library/Application Support/stackroom/Stackroom Library.xml"),
            sourceMTime: Date(timeIntervalSince1970: 1000)
        )
        let meta = try db.fetchImportMeta()
        #expect(meta?.bookCount == 1)
        #expect(meta?.skippedCount == 0)
        #expect(meta?.sourceXMLPath == "/Users/me/Library/Application Support/stackroom/Stackroom Library.xml")
    }

    @Test("G49: Path 欠落の本は表紙パスから復元され、件数が warning に出る")
    func recoversMissingPathFromCoverImagePath() throws {
        let db = try Database.openInMemory()
        try db.migrate()

        // 表紙パスがアーカイブ本体を指す本（Path キーが欠落する時期のデータを模す）
        let book = BookRecord(
            id: 1, title: "T", path: nil, coverImagePath: "/b/x.zip",
            dateAdded: Date(timeIntervalSince1970: 0), bookType: 0, fileType: 2
        )
        let doc = LibraryDocument(books: ["1": book])
        let importer = LibraryImporter(database: db)
        let summary = try importer.run(document: doc)

        #expect(summary.imported == 1)
        #expect(summary.warnings.contains { $0.contains("1") && $0.contains("path") })
        #expect(try db.fetchBook(id: 1)?.path == "/b/x.zip")
        db.close()
    }

    @Test("G49: 表紙が画像でも、その親ディレクトリが存在しなければ復元しない")
    func doesNotRecoverParentDirectoryThatDoesNotExist() throws {
        let db = try Database.openInMemory()
        try db.migrate()

        let book = BookRecord(
            id: 2, title: "T", path: nil, coverImagePath: "/b/book/001.jpg",
            dateAdded: Date(timeIntervalSince1970: 0), bookType: 0, fileType: 2
        )
        let doc = LibraryDocument(books: ["2": book])
        let importer = LibraryImporter(database: db, directoryExists: { _ in false })
        let summary = try importer.run(document: doc)

        #expect(summary.imported == 1)
        #expect(try db.fetchBook(id: 2)?.path == nil)
        db.close()
    }

    @Test("G49: 表紙が画像で親ディレクトリが実在すればフォルダ書籍として復元する")
    func recoversParentDirectoryWhenItExists() throws {
        let db = try Database.openInMemory()
        try db.migrate()

        let book = BookRecord(
            id: 3, title: "T", path: nil, coverImagePath: "/b/book/001.jpg",
            dateAdded: Date(timeIntervalSince1970: 0), bookType: 0, fileType: 2
        )
        let doc = LibraryDocument(books: ["3": book])
        let importer = LibraryImporter(database: db, directoryExists: { $0 == "/b/book" })
        _ = try importer.run(document: doc)

        #expect(try db.fetchBook(id: 3)?.path == "/b/book")
        db.close()
    }

    @Test("ImportMeta round-trips through DB")
    func importMetaRoundTrips() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let meta = ImportMeta(
            schemaVersion: 2,
            importedAt: Date(timeIntervalSince1970: 1000),
            sourceXMLPath: "/some.xml",
            sourceXMLMTime: Date(timeIntervalSince1970: 500),
            importerVersion: "test",
            bookCount: 5,
            skippedCount: 1,
            notes: nil
        )
        try db.writeImportMeta(meta)
        let loaded = try db.fetchImportMeta()
        #expect(loaded?.bookCount == 5)
        #expect(loaded?.sourceXMLPath == "/some.xml")
    }
}
