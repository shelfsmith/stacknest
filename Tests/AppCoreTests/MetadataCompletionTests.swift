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
        // "作品 第N巻" は FilenameParser.parse が series="作品"/volume=N として確実に
        // マッチする形式（"作品 N巻" は 第 prefix がなくマッチしないため patch が生成されず
        // ループ本体が一度も回らない＝キャンセル早期打ち切りを検証できない不具合があった）。
        for i in 1...5 {
            _ = try db.insertBookReturningID(BookRecord(
                id: 0, title: "作品 第\(i)巻", dateAdded: Date()))
        }
        var seen = 0
        let updated = try await MetadataCompletion.fillMissingSeriesVolume(
            in: db, progress: { done, _ in seen = done }, isCancelled: { seen >= 2 })
        // ループは各件の更新前に isCancelled() を確認する:
        //   1件目: isCancelled(seen=0)=false → 更新 → done=1 → progress → seen=1
        //   2件目: isCancelled(seen=1)=false → 更新 → done=2 → progress → seen=2
        //   3件目: isCancelled(seen=2)=true  → break（更新されない）
        // よって境界は厳密に 2 件で打ち切られる。
        #expect(updated == 2)
        #expect(seen == 2)
    }

    @Test func isCancelledFalseProcessesAll() async throws {
        // isCancelledStopsEarly の "== 2" が本当に早期打ち切りの結果であり、
        // 単に全件処理された結果ではないことを対比で示す。
        let db = try makeDB()
        for i in 1...5 {
            _ = try db.insertBookReturningID(BookRecord(
                id: 0, title: "作品 第\(i)巻", dateAdded: Date()))
        }
        let updated = try await MetadataCompletion.fillMissingSeriesVolume(
            in: db, progress: { _, _ in }, isCancelled: { false })
        #expect(updated == 5)
    }
}
