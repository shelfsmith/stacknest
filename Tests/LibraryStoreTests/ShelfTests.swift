// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
import StackroomFormat

@Suite("Shelf read APIs")
struct ShelfTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    @Test func fetchAllShelvesEmptyDB() throws {
        let db = try setupDB()
        let shelves = try db.fetchAllShelves()
        #expect(shelves.isEmpty)
    }

    @Test func fetchAllShelvesAfterImport() throws {
        let db = try setupDB()
        try db.insertPlaylist(PlaylistRecord(title: "Imported A", type: 0, items: []))
        try db.insertPlaylist(PlaylistRecord(title: "Imported B", type: 0, items: []))

        let shelves = try db.fetchAllShelves()
        #expect(shelves.count == 2)
        #expect(shelves.allSatisfy { $0.kind == "imported" })
        #expect(Set(shelves.map(\.title)) == ["Imported A", "Imported B"])
    }

    @Test func fetchPlaylistBookCount() throws {
        let db = try setupDB()
        // Insert 3 books
        for i in 1...3 {
            try db.insertBook(BookRow.testInstance(id: i, title: "B\(i)"))
        }
        try db.insertPlaylist(PlaylistRecord(
            title: "P", type: 0, items: [1, 2, 3]
        ))
        let shelves = try db.fetchAllShelves()
        guard let id = shelves.first?.id else { Issue.record("no shelf"); return }

        let count = try db.fetchPlaylistBookCount(playlistID: id)
        #expect(count == 3)
    }

    @Test func ensureFavoritesShelfCreatesIfMissing() throws {
        let db = try setupDB()
        let id1 = try db.ensureFavoritesShelf()
        #expect(id1 > 0)

        let shelves = try db.fetchAllShelves()
        let favs = shelves.filter { $0.kind == "favorites" }
        #expect(favs.count == 1)
        #expect(favs.first?.id == id1)
    }

    @Test func ensureFavoritesShelfIsIdempotent() throws {
        let db = try setupDB()
        let id1 = try db.ensureFavoritesShelf()
        let id2 = try db.ensureFavoritesShelf()
        let id3 = try db.ensureFavoritesShelf()
        #expect(id1 == id2)
        #expect(id2 == id3)

        let favCount = try db.fetchAllShelves().filter { $0.kind == "favorites" }.count
        #expect(favCount == 1)
    }

    @Test func fetchBooksInPlaylistOrderedByPosition() throws {
        let db = try setupDB()
        for i in 1...5 {
            try db.insertBook(BookRow.testInstance(id: i, title: "B\(i)"))
        }
        // Insert playlist with items in specific order [3, 1, 5, 2, 4]
        try db.insertPlaylist(PlaylistRecord(
            title: "P", type: 0, items: [3, 1, 5, 2, 4]
        ))
        let shelves = try db.fetchAllShelves()
        guard let id = shelves.first?.id else { Issue.record("no shelf"); return }

        let books = try db.fetchBooksInPlaylist(playlistID: id)
        #expect(books.map(\.id) == [3, 1, 5, 2, 4])
    }

    @Test func createUserShelf() throws {
        let db = try setupDB()
        let id = try db.createUserShelf(title: "My Shelf")
        let shelves = try db.fetchAllShelves()
        let s = shelves.first { $0.id == id }
        #expect(s != nil)
        #expect(s?.title == "My Shelf")
        #expect(s?.kind == "user")
    }

    @Test func renameShelf() throws {
        let db = try setupDB()
        let id = try db.createUserShelf(title: "Old")
        try db.renameShelf(id: id, title: "New")
        let s = try db.fetchAllShelves().first { $0.id == id }
        #expect(s?.title == "New")
    }

    @Test func deleteShelfCascadesItems() throws {
        let db = try setupDB()
        try db.insertBook(BookRow.testInstance(id: 1, title: "B1"))
        let id = try db.createUserShelf(title: "S")
        try db.appendBooksToShelf(playlistID: id, bookIDs: [1])
        #expect(try db.fetchPlaylistBookCount(playlistID: id) == 1)

        try db.deleteShelf(id: id)
        #expect(try db.fetchAllShelves().isEmpty)
        #expect(try db.fetchPlaylistItemCount() == 0)  // cascade verified
    }

    @Test func appendBooksToShelfDeduplicates() throws {
        let db = try setupDB()
        for i in 1...3 {
            try db.insertBook(BookRow.testInstance(id: i, title: "B\(i)"))
        }
        let id = try db.createUserShelf(title: "S")

        try db.appendBooksToShelf(playlistID: id, bookIDs: [1, 2])
        try db.appendBooksToShelf(playlistID: id, bookIDs: [2, 3])  // 2 is dup, only 3 added
        let books = try db.fetchBooksInPlaylist(playlistID: id)
        #expect(books.map(\.id) == [1, 2, 3])
    }

    @Test func removeBookFromShelf() throws {
        let db = try setupDB()
        for i in 1...3 {
            try db.insertBook(BookRow.testInstance(id: i, title: "B\(i)"))
        }
        let id = try db.createUserShelf(title: "S")
        try db.appendBooksToShelf(playlistID: id, bookIDs: [1, 2, 3])

        try db.removeBookFromShelf(playlistID: id, bookID: 2)
        let remaining = try db.fetchBooksInPlaylist(playlistID: id)
        #expect(remaining.map(\.id) == [1, 3])
    }

    @Test func removeBooksFromShelfBatch() throws {
        let db = try setupDB()
        for i in 1...3 {
            try db.insertBook(BookRow.testInstance(id: i, title: "B\(i)"))
        }
        let id = try db.createUserShelf(title: "S")
        try db.appendBooksToShelf(playlistID: id, bookIDs: [1, 2, 3])

        try db.removeBooksFromShelf(playlistID: id, bookIDs: [1, 3])
        let remaining = try db.fetchBooksInPlaylist(playlistID: id)
        #expect(remaining.map(\.id) == [2])
    }
}

// Test helper
extension BookRow {
    static func testInstance(id: Int, title: String) -> BookRow {
        BookRow(
            id: id, title: title, author: nil, genre: nil, path: nil,
            dateAdded: Date(),
            playDate: nil, bookType: 0, fileType: 0, pages: nil,
            rating: 0, unseen: false, keywordA: nil, keywordB: nil,
            keywordC: nil, neta: nil, memo: nil
        )
    }
}
