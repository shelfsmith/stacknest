// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
import StackroomFormat

@Suite("FTS5 Search")
struct SearchTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    private func insertBooks(_ db: Database) throws {
        try db.insertBook(makeBook(id: 1, title: "朝食会 第10巻", author: "渡邊ダイスケ", genre: "コミック"))
        try db.insertBook(makeBook(id: 2, title: "朝食会 第11巻", author: "渡邊ダイスケ", genre: "コミック"))
        try db.insertBook(makeBook(id: 3, title: "中年労働者", author: "佐々木ミノル", genre: "コミック"))
        try db.insertBook(makeBook(id: 4, title: "Notes on Programming", author: "Smith", genre: "Tech"))
    }

    private func makeBook(id: Int, title: String, author: String?, genre: String?) -> BookRow {
        BookRow(
            id: id, title: title, author: author, genre: genre, path: nil,
            dateAdded: Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 0, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil
        )
    }

    @Test func searchByTitleAcrossLibrary() throws {
        let db = try setupDB()
        try insertBooks(db)
        let results = try db.searchBooks(query: "朝食", sidebarScope: .library)
        #expect(Set(results.map(\.id)) == [1, 2])
    }

    @Test func searchByAuthor() throws {
        let db = try setupDB()
        try insertBooks(db)
        let results = try db.searchBooks(query: "佐々木", sidebarScope: .library)
        #expect(results.map(\.id) == [3])
    }

    @Test func searchInShelfScope() throws {
        let db = try setupDB()
        try insertBooks(db)
        // Create shelf containing books 1, 3
        try db.insertPlaylist(PlaylistRecord(title: "Mix", type: 0, items: [1, 3]))
        let shelves = try db.fetchAllShelves()
        guard let shelfID = shelves.first?.id else { Issue.record("no shelf"); return }

        let results = try db.searchBooks(query: "朝食", sidebarScope: .shelf(playlistID: shelfID))
        #expect(results.map(\.id) == [1])  // book 2 is in library but not in shelf
    }

    @Test func searchEmptyQueryReturnsAll() throws {
        let db = try setupDB()
        try insertBooks(db)
        let results = try db.searchBooks(query: "", sidebarScope: .library)
        #expect(results.count == 4)
    }

    @Test func searchSpecialCharsEscaped() throws {
        let db = try setupDB()
        try insertBooks(db)
        // FTS5 special chars: " ( ) : * etc. Should not crash.
        let results = try db.searchBooks(query: "\"hello\" (world)", sidebarScope: .library)
        // No crash expected; result may be empty or non-empty
        _ = results  // Just verifying it doesn't throw/crash
    }
}
