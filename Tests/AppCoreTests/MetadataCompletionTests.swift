// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore
import StackroomFormat

@Suite("MetadataCompletion")
struct MetadataCompletionTests {
    private func makeDB() throws -> Database {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc_\(UUID().uuidString).sqlite")
        let db = try Database.openFile(at: url, mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test func fillsOnlyEmptySeriesVolume() async throws {
        let db = try makeDB()
        // 空欄の本（title に巻数）→ 補完される
        let opID = try db.insertBookReturningID(BookRecord(
            id: 0, title: "ワンピース 第3巻", path: "/x/op3.zip", dateAdded: Date()))
        // 既に series/volume がある本 → 不変
        let nID = try db.insertBookReturningID(BookRecord(
            id: 0, title: "ナルト 5", path: "/x/n5.zip", dateAdded: Date(), series: "既存", volume: 99))

        let updated = try await MetadataCompletion.fillMissingSeriesVolume(
            in: db, progress: { _, _ in }, isCancelled: { false })

        #expect(updated == 1)
        let op = try db.fetchBook(id: opID)!
        #expect(op.series == "ワンピース")
        #expect(op.volume == 3)
        let n = try db.fetchBook(id: nID)!
        #expect(n.series == "既存")     // 非空欄は不変
        #expect(n.volume == 99)
    }

    @Test func isCancelledStopsEarly() async throws {
        let db = try makeDB()
        for i in 1...5 {
            _ = try db.insertBookReturningID(BookRecord(
                id: 0, title: "作品 \(i)巻", dateAdded: Date()))
        }
        var seen = 0
        let updated = try await MetadataCompletion.fillMissingSeriesVolume(
            in: db, progress: { done, _ in seen = done }, isCancelled: { seen >= 2 })
        #expect(updated <= 3)   // 2 件処理後に打ち切り（境界は実装依存で 2〜3）
    }
}
