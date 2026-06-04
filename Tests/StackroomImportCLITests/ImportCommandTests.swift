// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryStore
import StackroomFormat
@testable import StackroomImportCLI

@Suite("ImportCommand E2E (walking skeleton)")
struct ImportCommandWalkingSkeletonTests {
    @Test("Imports minimal-book.plist into a fresh SQLite file")
    func importsMinimalBook() throws {
        guard let fixtureURL = Bundle.module.url(forResource: "minimal-book", withExtension: "plist", subdirectory: "Fixtures") else {
            Issue.record("minimal-book.plist fixture not found in test bundle resources")
            return
        }
        let outURL = URL(fileURLWithPath: "/tmp/stackroom-import-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: outURL) }

        var cmd = ImportCommand()
        cmd.xml = fixtureURL.path
        cmd.out = outURL.path
        cmd.force = true
        cmd.quiet = true
        try cmd.run()

        #expect(FileManager.default.fileExists(atPath: outURL.path))
    }

    @Test("ProgressReporter receives one update per book processed")
    func progressReporterIsCalled() throws {
        final class Counter: ProgressReporter, @unchecked Sendable {
            var count = 0
            func reportProgress(processed: Int, total: Int) { count += 1 }
        }

        let url = URL(fileURLWithPath: "/tmp/progress-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try Database.openFile(at: url, mode: .createOrReplace)
        try db.migrate()
        let book = BookRecord(
            id: 1, title: "T", genre: "g", coverImagePath: "/c",
            dateAdded: Date(timeIntervalSince1970: 0),
            bookType: 0, fileType: 2, myRate: 0, unseen: false
        )
        let doc = LibraryDocument(books: ["1": book, "2": book])
        let counter = Counter()
        let importer = LibraryImporter(database: db)
        _ = try importer.run(document: doc, sourceURL: url, sourceMTime: Date(), progress: counter)
        #expect(counter.count == 2)
        db.close()
    }

    @Test("ImportCommand fails to parse when --xml is missing")
    func parsingFailsWithoutRequiredXML() throws {
        #expect(throws: (any Error).self) {
            _ = try ImportCommand.parse(["--out", "/tmp/x.sqlite", "--force"])
        }
    }

    @Test("ImportCommand fails to parse when --out is missing")
    func parsingFailsWithoutRequiredOut() throws {
        #expect(throws: (any Error).self) {
            _ = try ImportCommand.parse(["--xml", "/tmp/x.plist", "--force"])
        }
    }
}
