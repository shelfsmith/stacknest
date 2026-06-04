// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore
@testable import StackroomFormat

@Suite("SmartShelf CRUD")
struct SmartShelfCRUDTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }
    private func sampleConditions() -> SmartShelfConditions {
        SmartShelfConditions(match: .all, rules: [
            SmartShelfRule(id: UUID(), field: .genre, op: .contains, value: .text("コミック"))])
    }

    @Test func createAndFetchConditions() throws {
        let db = try setupDB()
        let original = sampleConditions()
        let id = try db.createSmartShelf(title: "新スマート", conditions: original)
        let fetched = try db.fetchSmartShelfConditions(id: id)
        #expect(fetched == original)
    }

    @Test func createdShelfIsSmartInList() throws {
        let db = try setupDB()
        _ = try db.createSmartShelf(title: "S", conditions: sampleConditions())
        let shelves = try db.fetchAllShelves()
        #expect(shelves.count == 1)
        #expect(shelves[0].isSmart == true)
        #expect(shelves[0].kind == "user")
    }

    @Test func manualShelfIsNotSmart() throws {
        let db = try setupDB()
        _ = try db.createUserShelf(title: "手動")
        let shelves = try db.fetchAllShelves()
        #expect(shelves[0].isSmart == false)
    }

    @Test func updateConditions() throws {
        let db = try setupDB()
        let id = try db.createSmartShelf(title: "S", conditions: sampleConditions())
        let updated = SmartShelfConditions(match: .any, rules: [
            SmartShelfRule(id: UUID(), field: .rating, op: .gte, value: .int(4))])
        try db.updateSmartShelfConditions(id: id, conditions: updated)
        #expect(try db.fetchSmartShelfConditions(id: id) == updated)
    }

    @Test func legacyConditionsDecodeViaFallback() throws {
        let db = try setupDB()
        // importer 経路と同じく PlaylistConditions の JSON を保存
        try db.insertPlaylist(PlaylistRecord(
            title: "旧スマート", type: 0,
            conditions: PlaylistConditions(
                dateCondition: DateCondition(condition: "Date Added", key: 30, option: 0),
                rateCondition: nil, keywordCondition: nil)))
        let shelves = try db.fetchAllShelves()
        #expect(shelves[0].isSmart == true)   // conditions IS NOT NULL
        let c = try db.fetchSmartShelfConditions(id: shelves[0].id)
        #expect(c?.rules.first?.field == .dateAdded)
        #expect(c?.rules.first?.value.asDays == 30)
    }
}
