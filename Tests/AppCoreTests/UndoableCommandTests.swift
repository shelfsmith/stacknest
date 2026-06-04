// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore
import StackroomFormat

@Suite("UndoableCommand")
struct UndoableCommandTests {
    private func makeDB() throws -> (Database, URL) {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undo-\(UUID()).sqlite")
        let db = try Database.openFile(at: tmpURL, mode: .createOrReplace)
        try db.migrate()
        return (db, tmpURL)
    }

    @Test
    func deleteBooksCommandRoundTrip() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let id1 = try db.insertBookReturningID(BookRecord(id: 0, title: "A", dateAdded: Date()))
        let id2 = try db.insertBookReturningID(BookRecord(id: 0, title: "B", dateAdded: Date()))
        let cmd = try DeleteBooksCommand.prepare(bookIDs: [id1, id2], database: db)
        try cmd.perform(database: db)
        #expect(try db.fetchAllBooks().count == 0)
        try cmd.undo(database: db)
        let restored = try db.fetchAllBooks()
        #expect(restored.count == 2)
        #expect(Set(restored.map(\.id)) == Set([id1, id2]))
        #expect(Set(restored.map(\.title)) == Set(["A", "B"]))
    }

    @Test
    func patchBooksCommandRoundTrip() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try db.insertBookReturningID(BookRecord(id: 0, title: "Untitled", dateAdded: Date()))
        let patch = BookPatch(title: "Patched")
        let cmd = try PatchBooksCommand.prepare(patches: [(id, patch)], database: db)
        try cmd.perform(database: db)
        #expect(try db.fetchAllBooks().first?.title == "Patched")
        try cmd.undo(database: db)
        #expect(try db.fetchAllBooks().first?.title == "Untitled")
    }

    @Test
    func patchBooksCommandHandlesMultipleBooks() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let id1 = try db.insertBookReturningID(BookRecord(id: 0, title: "A", genre: "旧", dateAdded: Date()))
        let id2 = try db.insertBookReturningID(BookRecord(id: 0, title: "B", genre: "旧", dateAdded: Date()))
        let patch = BookPatch(genre: "新ジャンル")
        let cmd = try PatchBooksCommand.prepare(
            patches: [(id1, patch), (id2, patch)], database: db
        )
        try cmd.perform(database: db)
        let after = try db.fetchAllBooks()
        #expect(after.allSatisfy { $0.genre == "新ジャンル" })
        try cmd.undo(database: db)
        let restored = try db.fetchAllBooks()
        #expect(restored.allSatisfy { $0.genre == "旧" })
    }

    @Test
    func patchBooksCommandPreservesSeriesAndVolume() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try db.insertBookReturningID(BookRecord(
            id: 0, title: "Original", dateAdded: Date(),
            series: "旧シリーズ", volume: 1.0
        ))
        let patch = BookPatch(series: "新シリーズ", volume: 2.0)
        let cmd = try PatchBooksCommand.prepare(patches: [(id, patch)], database: db)
        try cmd.perform(database: db)
        let after = try db.fetchAllBooks().first
        #expect(after?.series == "新シリーズ")
        #expect(after?.volume == 2.0)
        try cmd.undo(database: db)
        let restored = try db.fetchAllBooks().first
        #expect(restored?.series == "旧シリーズ")
        #expect(restored?.volume == 1.0)
    }

    @Test
    func patchCanClearVolumeToNull() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try db.insertBookReturningID(BookRecord(id: 0, title: "T", dateAdded: Date(), volume: 5.0))
        try db.updateBook(id: id, patch: BookPatch(clearVolume: true))
        let fetched = try db.fetchAllBooks().first
        #expect(fetched?.volume == nil)
    }

    @Test
    func patchUndoRestoresClearedVolume() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        // 元: volume=nil
        let id = try db.insertBookReturningID(BookRecord(id: 0, title: "T", dateAdded: Date()))
        // forward: volume=5.0 設定
        let cmd = try PatchBooksCommand.prepare(patches: [(id, BookPatch(volume: 5.0))], database: db)
        try cmd.perform(database: db)
        #expect(try db.fetchAllBooks().first?.volume == 5.0)
        // undo: もとの nil に戻る
        try cmd.undo(database: db)
        #expect(try db.fetchAllBooks().first?.volume == nil)
    }

    @Test
    func patchUndoRestoresSetCoverImageName() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        // 元: coverImageName=nil (= 自動)
        let id = try db.insertBookReturningID(BookRecord(id: 0, title: "T", dateAdded: Date()))
        // forward: coverImageName="page05.jpg" 設定
        let cmd = try PatchBooksCommand.prepare(patches: [(id, BookPatch(coverImageName: "page05.jpg"))], database: db)
        try cmd.perform(database: db)
        #expect(try db.fetchAllBooks().first?.coverImageName == "page05.jpg")
        // undo: nil (= 自動) に戻る
        try cmd.undo(database: db)
        #expect(try db.fetchAllBooks().first?.coverImageName == nil)
    }

    @Test
    func patchUndoRestoresClearedCoverImageName() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        // 元: coverImageName="page01.jpg" (= 手動指定済)
        let id = try db.insertBookReturningID(BookRecord(id: 0, title: "T", coverImageName: "page01.jpg", dateAdded: Date()))
        // forward: clearCoverImageName (= 自動に戻す)
        let cmd = try PatchBooksCommand.prepare(patches: [(id, BookPatch(clearCoverImageName: true))], database: db)
        try cmd.perform(database: db)
        #expect(try db.fetchAllBooks().first?.coverImageName == nil)
        // undo: 元の "page01.jpg" に戻る
        try cmd.undo(database: db)
        #expect(try db.fetchAllBooks().first?.coverImageName == "page01.jpg")
    }

    /// Fix 1 regression: recompute undo correctly restores NULL series/volume.
    /// Simulates recomputeMetadataFromFilenames path: book starts with series=nil, volume=nil,
    /// gets series/volume patched, then undo should return them to nil.
    @Test
    func recomputeUndoRestoresNullValues() throws {
        let (db, url) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try db.insertBookReturningID(BookRecord(id: 0, title: "ワンピース 第5巻", dateAdded: Date()))
        // 元状態: series = nil, volume = nil
        #expect(try db.fetchAllBooks().first?.series == nil)
        #expect(try db.fetchAllBooks().first?.volume == nil)

        // recompute 経路を直接シミュレート: patch を直接作って PatchBooksCommand
        let patch = BookPatch(series: "ワンピース", volume: 5.0)
        let cmd = try PatchBooksCommand.prepare(patches: [(bookID: id, patch: patch)], database: db)
        try cmd.perform(database: db)
        #expect(try db.fetchAllBooks().first?.series == "ワンピース")
        #expect(try db.fetchAllBooks().first?.volume == 5.0)

        // undo で NULL に戻る期待
        try cmd.undo(database: db)
        #expect(try db.fetchAllBooks().first?.series == nil)
        #expect(try db.fetchAllBooks().first?.volume == nil)
    }
}
