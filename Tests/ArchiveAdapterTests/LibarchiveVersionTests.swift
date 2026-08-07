// SPDX-License-Identifier: MIT
import Testing
import ArchiveAdapter

@Suite("libarchive のヘッダと実行時ライブラリの版一致（G28 / G30）")
struct LibarchiveVersionTests {
    /// コンパイルに使ったヘッダと、実際にリンクされる Apple のライブラリの版が一致すること。
    ///
    /// G30: 値は `ArchiveAdapter.LibarchiveVersion` から取る（`Carchive` を直接 import しない）。
    /// これにより **App ターゲットのテストからも同じ判定ができる**（`Carchive` は product では
    /// ないため App からは import できない）。
    ///
    /// **限界（2026-08-07 実測）**: `ARCHIVE_VERSION_NUMBER` はコンパイル時に焼き付くが、
    /// SwiftPM は `vendor/` の有無が変わってもこのターゲットを再コンパイルしない
    /// （`__has_include` の解決先の変化を依存グラフが追えないため）。
    /// 実際に `vendor/` を退避しても本テストは **古い PASS を返し続けた**
    /// （ModuleCache を消しても変わらず、ソースを touch して初めて正しくなった）。
    /// そのため `Scripts/fetch-libarchive-headers.sh` は判定を確定させた時点で
    /// `Carchive.h` とテストソースを touch する。クリーンビルドの結果は常に正しいが、
    /// **インクリメンタルビルドでは最後にコンパイルされた時点の判定**である点に注意。
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
