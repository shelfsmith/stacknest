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

/// `mdutil -s` / `mdfind` の出力解析。**実 I/O を伴わない部分をここで固定する。**
///
/// 元の実装は判定を関数の中に埋め込んでおり、**spec §3.3 が最も懸念していた
/// 「マウント済みだが索引無効」のケースがテストで一度も通っていなかった**
/// （実装者の指摘。`aMissingVolumeIsTreatedAsNotIndexed` は `fileExists` ガードで
/// 先に false になり、判定そのものに到達しない）。
@Suite("Spotlight の出力解析（G39）")
struct SpotlightOutputParsingTests {
    /// 実機で確認した 3 表現。
    @Test func readsTheThreeStatesMdutilActuallyPrints() {
        #expect(SpotlightTagQuery.parseIndexingState("/Volumes/comic:\n\tIndexing enabled.") == true)
        #expect(SpotlightTagQuery.parseIndexingState("/Volumes/download:\n\tIndexing disabled.") == false)
        #expect(SpotlightTagQuery.parseIndexingState(
            "/Volumes/DATA04:\n\tIndexing and searching disabled.") == false,
            "★ これを取り違えると、索引が無いのに有効と判定して庫じゅうのタグを消しかねない")
    }

    /// 「無効」の表現が「Indexing」で始まるため、**有効を先に見ると誤判定する**。
    @Test func aDisabledStateIsNotMistakenForAnEnabledOne() {
        #expect(SpotlightTagQuery.parseIndexingState("Indexing and searching disabled.") == false)
    }

    @Test func anUnexpectedOutputIsTreatedAsNotIndexed() {
        #expect(SpotlightTagQuery.parseIndexingState("") == false)
        #expect(SpotlightTagQuery.parseIndexingState("Error: invalid path") == false)
    }

    @Test func splitsMdfindOutputIntoPaths() {
        #expect(SpotlightTagQuery.parsePaths("/a/b.zip\n/c/d.zip\n") == ["/a/b.zip", "/c/d.zip"])
        #expect(SpotlightTagQuery.parsePaths("").isEmpty)
        #expect(SpotlightTagQuery.parsePaths("\n\n").isEmpty)
    }

    /// パスに空白が含まれていても 1 行 1 パスとして正しく割れること
    /// （`mdfind` は改行区切りで返す。空白で割ってはいけない）。
    @Test func pathsWithSpacesStayIntact() {
        #expect(SpotlightTagQuery.parsePaths("/Volumes/comic/(一般コミック) [作者] 本 第01巻.zip")
                == ["/Volumes/comic/(一般コミック) [作者] 本 第01巻.zip"])
    }
}
