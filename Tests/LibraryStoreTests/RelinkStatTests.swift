// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("relink stats new file")
struct RelinkStatTests {
    private func freshDB() throws -> Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relink_stat_\(UUID().uuidString).sqlite")
        let db = try Database.openFile(at: url, mode: .createOrReplace)
        try db.migrate()
        return db
    }

    private func insertBook(_ db: Database, id: Int, path: String) throws {
        try db.insertBook(BookRow(
            id: id, title: "Book \(id)", author: nil, genre: nil, path: path,
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0,
            pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil
        ))
    }

    @Test func relinkSetsMtimeAndSizeFromNewFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.cbz"); try Data(repeating: 1, count: 100).write(to: a)
        let b = dir.appendingPathComponent("b.cbz"); try Data(repeating: 2, count: 250).write(to: b)

        let db = try freshDB()
        try insertBook(db, id: 1, path: a.path)
        try db.relinkBook(id: 1, newPath: b.path)
        let row = try #require(try db.fetchBook(id: 1))
        #expect(row.path == b.path)
        #expect(row.fileSize == 250)                       // 新ファイルの size
        #expect((row.fileMtime ?? 0) > 0)                  // 新ファイルの mtime がセットされている
        #expect(row.contentHash == nil)                    // hash は NULL のまま（別途 rehash）
    }

    @Test func applyRelinksSetsMtimeAndSizeFromNewFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a1 = dir.appendingPathComponent("a1.cbz"); try Data(repeating: 1, count: 10).write(to: a1)
        let b1 = dir.appendingPathComponent("b1.cbz"); try Data(repeating: 2, count: 20).write(to: b1)
        let a2 = dir.appendingPathComponent("a2.cbz"); try Data(repeating: 3, count: 30).write(to: a2)
        let b2 = dir.appendingPathComponent("b2.cbz"); try Data(repeating: 4, count: 40).write(to: b2)

        let db = try freshDB()
        try insertBook(db, id: 1, path: a1.path)
        try insertBook(db, id: 2, path: a2.path)

        try db.applyRelinks([
            (id: 1, newPath: b1.path),
            (id: 2, newPath: b2.path),
        ])

        let row1 = try #require(try db.fetchBook(id: 1))
        let row2 = try #require(try db.fetchBook(id: 2))
        #expect(row1.fileSize == 20)
        #expect((row1.fileMtime ?? 0) > 0)
        #expect(row2.fileSize == 40)
        #expect((row2.fileMtime ?? 0) > 0)
    }
}
