// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("Spotlight でタグ付き項目を引く（G39）")
struct SpotlightTagQueryTests {
    /// 索引の有効/無効が判定できること。**判定できないと、黙って同期されない状態になる**（spec §3.3）。
    @Test func reportsIndexingStateForTheBootVolume() {
        // 起動ボリュームは通常有効。false でもテストは落とさない（環境依存）ので、
        // 「例外を投げず Bool を返す」ことだけを固定する。
        _ = SpotlightTagQuery.isIndexingEnabled(volume: URL(fileURLWithPath: "/"))
    }

    /// 存在しないボリュームでも落ちない（無効として扱う）。
    @Test func aMissingVolumeIsTreatedAsNotIndexed() {
        #expect(SpotlightTagQuery.isIndexingEnabled(
            volume: URL(fileURLWithPath: "/Volumes/no-such-volume-\(UUID().uuidString)")) == false)
    }

    /// クエリが例外を投げずに配列を返すこと。件数は索引の反映待ちに依存するので固定しない。
    @Test func queryingReturnsWithoutThrowing() throws {
        _ = try SpotlightTagQuery.taggedPaths(in: URL(fileURLWithPath: "/"))
    }
}
