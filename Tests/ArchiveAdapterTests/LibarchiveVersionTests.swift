// SPDX-License-Identifier: MIT
import Testing
import ArchiveAdapter

@Suite("libarchive のヘッダと実行時ライブラリの版一致（G28 / G30）")
struct LibarchiveVersionTests {
    /// コンパイルに使ったヘッダと、実際にリンクされる Apple のライブラリの版が一致すること。
    ///
    /// G30: 値は `ArchiveAdapter.LibarchiveVersion` から取る（`Carchive` を直接 import しない）。
    /// **App ターゲットのテストも同じ値を見る**ので、判定は 1 つのコンパイル単位に集約される
    /// （理由は `LibarchiveVersion.swift` の doc コメント参照）。
    ///
    /// **限界（2026-08-07 実測、G30 で機構を更新）**: `ARCHIVE_VERSION_NUMBER` はコンパイル時に
    /// 焼き付くが、SwiftPM は `vendor/` の有無が変わっても関連ターゲットを再コンパイルしない
    /// （`__has_include` の解決先の変化を依存グラフが追えないため）。
    /// 実際に `vendor/` を退避しても本テストは **古い PASS を返し続けた**
    /// （ModuleCache を消しても変わらず、ソースを touch して初めて正しくなった）。
    ///
    /// G30 で判定の実値は `Sources/ArchiveAdapter/LibarchiveVersion.swift` の**1 箇所だけ**に
    /// 焼き付くようになった（本テストはそこから読むだけで自身では計算しない）。
    /// そのため陳腐化しうる箇所は「値の計算元（`LibarchiveVersion.swift`）」と
    /// 「Carchive の Clang PCM（`Carchive.h`）」の 2 つに絞られ、
    /// `Scripts/fetch-libarchive-headers.sh` は判定を確定させた時点でこの 2 つを touch する
    /// （**このテストファイル自身は touch 対象ではない** ―― 2026-08-08 実測: `Carchive.h` と
    /// このファイルだけを touch し `LibarchiveVersion.swift` を touch しない場合、判定は
    /// 古いまま更新されなかった）。クリーンビルドの結果は常に正しいが、
    /// **インクリメンタルビルドでは `LibarchiveVersion.swift` が最後にコンパイルされた時点の
    /// 判定**である点に注意。
    ///
    /// **本テストの挙動を手で確かめるときの落とし穴**: `ARCHIVE_VERSION_NUMBER` は
    /// `archive.h` だけでなく **`archive_entry.h` でも定義されている**（libarchive 3.7.4 では
    /// 前者 37 行目・後者 31 行目）。`Carchive.h` は archive.h → archive_entry.h の順に
    /// include するので、**後から読まれる `archive_entry.h` の値が勝つ**。
    /// `archive.h` だけ書き換えても実効値は変わらない ―― 2026-08-07 に controller と
    /// レビュアーが揃ってこれに引っかかり、「テストが古い値を返す」という誤った結論を出した。
    /// 検証時は必ず両方を書き換え、`clang -E -dM ... -include Carchive.h` で実効値を確認すること。
    @Test("ヘッダと実行時ライブラリの版が一致する")
    func headerMatchesRuntime() {
        #expect(LibarchiveVersion.header == LibarchiveVersion.runtime,
                "\(LibarchiveVersion.mismatchMessage)")
    }
}
