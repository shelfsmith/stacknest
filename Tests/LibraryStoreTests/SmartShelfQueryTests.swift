// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
import StackroomFormat

@Suite("SmartShelf query integration")
struct SmartShelfQueryTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }
    private func book(_ id: Int, _ title: String, genre: String? = nil, rating: Int = 0) -> BookRow {
        BookRow(id: id, title: title, author: nil, genre: genre, path: nil,
                dateAdded: Date(), playDate: nil, bookType: 0, fileType: 0, pages: nil,
                rating: rating, unseen: false, keywordA: nil, keywordB: nil,
                keywordC: nil, neta: nil, memo: nil, series: nil, volume: nil,
                coverImageName: nil, coverCropRect: nil)
    }

    @Test func smartShelfEvaluatesConditionsDynamically() throws {
        let db = try setupDB()
        try db.insertBook(book(1, "A", genre: "コミック", rating: 5))
        try db.insertBook(book(2, "B", genre: "小説", rating: 5))
        try db.insertBook(book(3, "C", genre: "コミック", rating: 1))
        let id = try db.createSmartShelf(title: "高評価コミック", conditions:
            SmartShelfConditions(match: .all, rules: [
                SmartShelfRule(id: UUID(), field: .genre, op: .contains, value: .text("コミック")),
                SmartShelfRule(id: UUID(), field: .rating, op: .gte, value: .int(3)),
            ]))
        let result = try db.searchBooks(query: "", sidebarScope: .smartShelf(playlistID: id))
        #expect(Set(result.map(\.id)) == [1])
    }

    @Test func smartShelfAnyCombinator() throws {
        let db = try setupDB()
        try db.insertBook(book(1, "A", genre: "コミック", rating: 1))
        try db.insertBook(book(2, "B", genre: "小説", rating: 5))
        try db.insertBook(book(3, "C", genre: "雑誌", rating: 1))
        let id = try db.createSmartShelf(title: "OR", conditions:
            SmartShelfConditions(match: .any, rules: [
                SmartShelfRule(id: UUID(), field: .genre, op: .equals, value: .text("コミック")),
                SmartShelfRule(id: UUID(), field: .rating, op: .gte, value: .int(5)),
            ]))
        let result = try db.searchBooks(query: "", sidebarScope: .smartShelf(playlistID: id))
        #expect(Set(result.map(\.id)) == [1, 2])
    }

    @Test func smartShelfComposedWithFacetFilter() throws {
        let db = try setupDB()
        try db.insertBook(book(1, "A", genre: "コミック", rating: 5))
        try db.insertBook(book(2, "B", genre: "コミック", rating: 2))
        let id = try db.createSmartShelf(title: "コミック", conditions:
            SmartShelfConditions(match: .all, rules: [
                SmartShelfRule(id: UUID(), field: .genre, op: .contains, value: .text("コミック"))]))
        var filter = FilterState()
        filter.ratingMin = 3
        let result = try db.searchBooks(query: "", sidebarScope: .smartShelf(playlistID: id), filter: filter)
        #expect(Set(result.map(\.id)) == [1])   // smart(コミック) ∧ facet(rating>=3)
    }

    @Test func smartShelfComposedWithFTSSearch() throws {
        let db = try setupDB()
        try db.insertBook(book(1, "ハイスコアガール", genre: "コミック", rating: 5))
        try db.insertBook(book(2, "別作品", genre: "コミック", rating: 5))
        let id = try db.createSmartShelf(title: "コミック", conditions:
            SmartShelfConditions(match: .all, rules: [
                SmartShelfRule(id: UUID(), field: .genre, op: .contains, value: .text("コミック"))]))
        let result = try db.searchBooks(query: "ハイスコア", sidebarScope: .smartShelf(playlistID: id))
        #expect(Set(result.map(\.id)) == [1])
    }

    @Test func importedSmartShelfEvaluatedNotCachedItems() throws {
        let db = try setupDB()
        try db.insertBook(book(1, "match", genre: "コミック"))
        try db.insertBook(book(2, "stale", genre: "小説"))
        try db.insertPlaylist(PlaylistRecord(
            title: "旧スマート", type: 0, items: [2],   // 静的キャッシュ（古い）
            conditions: nil))
        let shelves = try db.fetchAllShelves()
        let sid = shelves[0].id
        try db.updateSmartShelfConditions(id: sid, conditions:
            SmartShelfConditions(match: .all, rules: [
                SmartShelfRule(id: UUID(), field: .genre, op: .contains, value: .text("コミック"))]))
        let result = try db.searchBooks(query: "", sidebarScope: .smartShelf(playlistID: sid))
        #expect(Set(result.map(\.id)) == [1])   // 条件評価（cached Items=[2] は無視）
    }
}
