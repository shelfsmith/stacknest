// SPDX-License-Identifier: MIT
import Testing
import Foundation
import GRDB
@testable import AppCore
@testable import LibraryStore

@Suite("LibraryBundleCreator")
struct LibraryBundleCreatorTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("creator-test-\(UUID().uuidString).stacknest")
    }

    @Test("createEmpty produces a valid bundle with empty DB")
    func createEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try LibraryBundleCreator.createEmpty(at: url)

        try bundle.validate()  // does not throw

        // DB exists and migrates fully (no further ops should change it)
        let db = try Database.openExisting(at: bundle.databaseURL)
        try db.migrate()
        let bookCount = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book") ?? -1
        }
        #expect(bookCount == 0)
    }

    @Test("createEmpty throws if URL already exists")
    func createEmptyAlreadyExists() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: LibraryBundleError.alreadyExists(url)) {
            try LibraryBundleCreator.createEmpty(at: url)
        }
    }

    @Test("createEmpty Info.plist contains expected version")
    func createEmptyInfoPlist() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try LibraryBundleCreator.createEmpty(at: url)
        let data = try Data(contentsOf: bundle.infoPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(plist?[LibraryBundle.bundleVersionKey] as? Int == 1)
        #expect(plist?[LibraryBundle.bundleIdentifierKey] as? String == "app.shelfsmith.stacknest.library")
    }

    @Test("createEmpty seeds filename_format default via Migration v9")
    func newBundleHasFilenameFormatDefault() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try LibraryBundleCreator.createEmpty(at: url)

        let db = try Database.openExisting(at: bundle.databaseURL)
        defer { db.close() }
        let value = try db.getLibrarySetting(key: "filename_format")
        #expect(value == "(@genre) [@keywordB] [@author] @title")
    }
}
