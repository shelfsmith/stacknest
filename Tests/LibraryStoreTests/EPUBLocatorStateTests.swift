// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
import StackroomFormat

@Suite("EPUB の読書位置の永続化（v20）")
struct EPUBLocatorStateTests {
    /// Inserts a minimal book and returns its new id (既存 ViewerStateTests の作法に倣う)。
    private func insertBook(_ db: Database, title: String) throws -> Int {
        let rec = BookRecord(
            id: 0,
            title: title,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            series: nil,
            volume: nil
        )
        return try db.insertBookReturningID(rec)
    }

    @Test("行が無い本に書くと INSERT され、読める")
    func insertsWhenMissing() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "x")
        try db.updateEPUBLocator(bookID: id, json: #"{"spine":1,"progress":0.5}"#)
        let s = try db.loadViewerState(bookID: id)
        #expect(s.epubLocatorJSON == #"{"spine":1,"progress":0.5}"#)
        #expect(s.hasPersistedState == true)
        db.close()
    }

    @Test("後勝ち（比較せず上書き）。lastPage 等は保持")
    func lastWriteWins() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try insertBook(db, title: "x")
        try db.saveViewerState(bookID: id, spreadEnabled: true, coverOffset: false, lastPage: 7)
        try db.updateEPUBLocator(bookID: id, json: "A")
        try db.updateEPUBLocator(bookID: id, json: "B")
        let s = try db.loadViewerState(bookID: id)
        #expect(s.epubLocatorJSON == "B" && s.lastPage == 7 && s.spreadEnabled == true)
        db.close()
    }

    @Test("v20 は冪等（2 回 migrate しても壊れない）")
    func migrationIdempotent() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        try db.migrate()
        #expect(try db.loadViewerState(bookID: 999).epubLocatorJSON == nil)
        db.close()
    }
}
