// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G36 ②: `FolderWatcher` のバッチ集計が `cancelled` を落とさないこと。
///
/// `FolderWatcher.scanAll` は取り込みをプリセット単位のバッチに分け、結果を
/// **フィールドごとに手で畳んでいる**。新しいフィールドを足しても畳み込みは自動では追随しない
/// ―― `cancelled` を立てる唯一の経路が `FolderWatcher` なので、写し忘れると
/// **フィールドが恒久的に死ぬ**（プレフライト走査で実際に見つかった欠陥）。
@Suite("ImportResult の畳み込み（G36）")
struct FolderWatcherImportResultMergeTests {

    @Test("どれか 1 バッチが中断されたら畳み込み後も cancelled が立つ")
    func mergePreservesCancelled() {
        var total = BookImporter.ImportResult()
        var first = BookImporter.ImportResult()
        first.addedIDs = [1, 2]
        var second = BookImporter.ImportResult()
        second.cancelled = true

        for r in [first, second] { total.merge(r) }

        #expect(total.cancelled == true)
        #expect(total.addedIDs == [1, 2], "中断を理由に取り込めた分を捨てない")
    }

    @Test("どのバッチも中断されなければ false のまま")
    func mergeKeepsFalseWhenNoneCancelled() {
        var total = BookImporter.ImportResult()
        var a = BookImporter.ImportResult(); a.addedIDs = [1]
        var b = BookImporter.ImportResult(); b.addedIDs = [2]

        for r in [a, b] { total.merge(r) }

        #expect(total.cancelled == false)
        #expect(total.addedIDs == [1, 2])
    }

    @Test("既に立っている cancelled を後続バッチが下ろさない")
    func laterBatchDoesNotClearCancelled() {
        var total = BookImporter.ImportResult()
        var cancelledBatch = BookImporter.ImportResult(); cancelledBatch.cancelled = true
        let normalBatch = BookImporter.ImportResult()

        total.merge(cancelledBatch)
        total.merge(normalBatch)

        #expect(total.cancelled == true)
    }

    @Test("他のフィールドも従来どおり足し込まれる")
    func mergeAccumulatesEveryField() {
        var total = BookImporter.ImportResult()
        var a = BookImporter.ImportResult()
        a.addedIDs = [1]; a.coverFailures = [URL(fileURLWithPath: "/a")]
        a.alreadyPresent = [URL(fileURLWithPath: "/b")]
        var b = BookImporter.ImportResult()
        b.addedIDs = [2]; b.coverFailures = [URL(fileURLWithPath: "/c")]

        total.merge(a); total.merge(b)

        #expect(total.addedIDs == [1, 2])
        #expect(total.coverFailures.count == 2)
        #expect(total.alreadyPresent.count == 1)
    }
}
