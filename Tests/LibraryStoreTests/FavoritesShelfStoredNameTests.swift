// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// G55: 英語化しても、DB に保存するお気に入りシェルフの名前は日本語のまま（保存値は訳さない・spec §5）。
/// 表示は App／リモートの側で kind == "favorites" を見て訳す。
@Suite("お気に入りシェルフの保存名（G55）")
struct FavoritesShelfStoredNameTests {
    @Test("ensureFavoritesShelf は名前「お気に入り」で作る")
    func storedNameIsJapanese() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        let id = try db.ensureFavoritesShelf()
        let row = try #require(try db.fetchAllShelves().first { $0.id == id })
        #expect(row.kind == "favorites")
        #expect(row.title == "お気に入り")
    }
}
