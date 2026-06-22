// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryStore
@testable import AppCore

@Suite("BookImporter")
struct BookImporterTests {
    private func makeImporter() throws -> (BookImporter, Database, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openInMemory()
        try db.migrate()
        let fmt = try FilenameFormat(raw: "@title")
        let importer = BookImporter(database: db, bundleURL: dir, format: fmt)
        return (importer, db, dir)
    }

    @Test func addsSingleImageAndSkipsDuplicatePath() async throws {
        let (importer, db, dir) = try makeImporter()
        let png = dir.appendingPathComponent("sample.png")
        try Self.onePixelPNG().write(to: png)

        let r1 = await importer.add(urls: [png], autoClassifyEnabled: false, thickThreshold: 100)
        #expect(r1.addedIDs.count == 1)
        #expect(try db.fetchAllBooks().count == 1)

        let r2 = await importer.add(urls: [png], autoClassifyEnabled: false, thickThreshold: 100)
        #expect(r2.addedIDs.isEmpty)
        #expect(r2.alreadyPresent == [png])
        #expect(try db.fetchAllBooks().count == 1)
    }

    private static func onePixelPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
    }
}
