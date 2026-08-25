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

    /// ★ 有効と無効を同時に述べる出力は「無効」に倒すこと。
    ///
    /// 実機の 3 表現に対しては、この判定は素朴な `contains("Indexing enabled")` と同じ結果になる
    /// ——**ガードは何もしていない**（レビューが変異で確認）。効くのはこの形の入力だけ。
    /// `mdfind` が使えない状態を「有効」と読むと、検索結果が空になり
    /// **庫じゅうのタグを消しかねない**ので、安全側に倒す。
    @Test func anOutputThatSaysBothIsTreatedAsDisabled() {
        #expect(SpotlightTagQuery.parseIndexingState("Indexing enabled, searching disabled.") == false)
        #expect(SpotlightTagQuery.parseIndexingState("Indexing enabled. Searching disabled.") == false)
    }

    /// 実機で見つかった 4 つ目の表現（Time Machine のローカルスナップショット）。
    @Test func anUnknownStateIsTreatedAsNotIndexed() {
        #expect(SpotlightTagQuery.parseIndexingState("Error: unknown indexing state.") == false)
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

/// Codex レビュー P2（2026-08-25）: **起動できたことと、成功したことは別。**
///
/// `run` が `terminationStatus` を見ていなかったため、`mdfind` が失敗して空を返しただけの状態を
/// 「タグの付いた項目は 0 件」と読み、**Finder → 庫の取り込みが黙って行われないまま
/// 成功と報告されて**いた。「空」を根拠に何かを決めてはいけないという点で spec §4.5 と同じ話
/// （あちらは削除、こちらは追加）。
///
/// **実コマンド経由では作れない**: `mdfind` は存在しないボリュームでも壊れたクエリでも
/// exit 0 を返す（2026-08-25 実測）。だから `run` を直接叩く。
@Suite("Spotlight コマンドの終了コード（G39・Codex P2）")
struct SpotlightTagQueryExitStatusTests {

    @Test("非 0 終了は失敗として投げる")
    func nonZeroExitThrows() {
        #expect(throws: SpotlightQueryError.commandFailed(command: "false", status: 1)) {
            _ = try SpotlightTagQuery.run("/usr/bin/false", [])
        }
    }

    /// 対照: 0 終了なら標準出力をそのまま返す（投げない）。
    @Test("0 終了なら出力を返す（対照）")
    func zeroExitReturnsOutput() throws {
        let out = try SpotlightTagQuery.run("/bin/echo", ["/a/b.cbz"])
        #expect(SpotlightTagQuery.parsePaths(out) == ["/a/b.cbz"])
    }

    /// 起動そのものに失敗した場合は従来どおり投げる（挙動を変えていない）。
    @Test("起動できなければ投げる")
    func launchFailureStillThrows() {
        #expect(throws: (any Error).self) {
            _ = try SpotlightTagQuery.run("/usr/bin/no-such-command-\(UUID().uuidString)", [])
        }
    }
}
