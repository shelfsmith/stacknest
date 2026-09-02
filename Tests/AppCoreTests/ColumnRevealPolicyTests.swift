// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("列を表示にしたときにスクロールする先")
struct ColumnRevealPolicyTests {
    // 実際のテーブルは title が必ず先頭。リモートはさらに "dl" 列が先頭に付く。
    private let ids = ["dl", "title", "author", "unseen", "play_date"]

    @Test("ON にしたらその列のインデックス")
    func revealsToggledOnColumn() {
        #expect(ColumnRevealPolicy.indexToReveal(toggled: .unseen, nowVisible: true, columnIdentifiers: ids) == 3)
    }

    @Test("OFF にしたら nil（何もしない）")
    func nothingWhenToggledOff() {
        #expect(ColumnRevealPolicy.indexToReveal(toggled: .unseen, nowVisible: false, columnIdentifiers: ids) == nil)
    }

    @Test("ON にしたが列が見つからないなら nil")
    func nilWhenColumnMissing() {
        #expect(ColumnRevealPolicy.indexToReveal(toggled: .genre, nowVisible: true, columnIdentifiers: ids) == nil)
    }

    @Test("先頭の列でも 0 を返す（『常に 0』の誤実装と区別するため末尾の列も見る）")
    func firstAndLast() {
        #expect(ColumnRevealPolicy.indexToReveal(toggled: .title, nowVisible: true, columnIdentifiers: ids) == 1)
        #expect(ColumnRevealPolicy.indexToReveal(toggled: .playDate, nowVisible: true, columnIdentifiers: ids) == 4)
    }
}
