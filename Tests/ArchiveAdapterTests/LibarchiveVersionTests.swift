// SPDX-License-Identifier: MIT
import Testing
import Carchive

@Suite("libarchive のヘッダと実行時ライブラリの版一致（G28）")
struct LibarchiveVersionTests {
    /// コンパイルに使ったヘッダと、実際にリンクされる Apple のライブラリの版が一致すること。
    ///
    /// ずれると「両方に存在するが意味・戻り値が変わった API」で静かに誤動作しうる。
    /// 実例: ディレクトリエントリに対する `archive_read_data` の戻り値は
    /// Homebrew 3.8.9 で -30、Apple 3.7.4 で -25 と異なった（2026-08-07 実測）。
    ///
    /// **限界（2026-08-07 実測）**: `ARCHIVE_VERSION_NUMBER` はコンパイル時に焼き付くが、
    /// SwiftPM は `vendor/` の有無が変わってもこのテストターゲットを再コンパイルしない
    /// （`__has_include` の解決先の変化を依存グラフが追えないため）。
    /// 実際に `vendor/` を退避しても本テストは **古い PASS を返し続けた**
    /// （ModuleCache を消しても変わらず、このファイルを touch して初めて正しくなった）。
    /// そのため `Scripts/fetch-libarchive-headers.sh` は判定を確定させた時点で本ファイルを
    /// touch する。クリーンビルドの結果は常に正しいが、**インクリメンタルビルドでは
    /// 本テストは最後にコンパイルされた時点の判定**である点に注意すること。
    @Test("ヘッダと実行時ライブラリの版が一致する")
    func headerMatchesRuntime() {
        let header = ARCHIVE_VERSION_NUMBER
        let runtime = archive_version_number()
        #expect(header == runtime, """
            libarchive のヘッダ（\(header)）と実行時ライブラリ（\(runtime)）の版が違います。
            次を実行してヘッダを取得し直してください:
              ./Scripts/fetch-libarchive-headers.sh
            """)
    }
}
