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

    /// Codex review Important #2 の回帰テスト: 処理中（1件目完了〜2件目着手の間）に別クライアントが
    /// 2件目の series を編集した場合、その編集はジョブ起動時の古い推測値で上書きされない。
    /// 旧実装（`missingSeriesVolumePatches` の事前スナップショット patch をそのまま適用）は、
    /// ループ開始時点で計算した patch を無条件適用するため、ここで挿入する編集を "作品" で
    /// 上書きしてしまっていた。新実装は適用直前に DB を再読込して空欄チェックをやり直す。
    @Test func doesNotOverwriteConcurrentEditDuringRun() async throws {
        let db = try makeDB()
        // date_added DESC で fetchAllBooks が並ぶため、id1 を新しい日時にして先頭（先に処理）にする。
        let id1 = try db.insertBookReturningID(BookRecord(
            id: 0, title: "作品 第1巻", dateAdded: Date()))
        let id2 = try db.insertBookReturningID(BookRecord(
            id: 0, title: "作品 第2巻", dateAdded: Date().addingTimeInterval(-10)))

        let updated = try await MetadataCompletion.fillMissingSeriesVolume(
            in: db,
            progress: { done, _ in
                // id1（1件目）の適用完了直後、id2（2件目）着手前に外部編集が入ったとシミュレート。
                if done == 1 {
                    var manual = BookPatch()
                    manual.series = "他クライアント編集"
                    try? db.updateBook(id: id2, patch: manual)
                }
            },
            isCancelled: { false })

        let fresh1 = try db.fetchBook(id: id1)!
        #expect(fresh1.series == "作品")
        #expect(fresh1.volume == 1)

        let fresh2 = try db.fetchBook(id: id2)!
        #expect(fresh2.series == "他クライアント編集")   // 古い推測値 "作品" で上書きされない
        #expect(fresh2.volume == 2)                        // volume は編集と無関係なので埋まる

        #expect(updated == 2)   // id1: series+volume（1回の update）／id2: volume のみ（1回の update）
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
