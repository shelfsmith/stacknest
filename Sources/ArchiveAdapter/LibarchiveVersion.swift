// SPDX-License-Identifier: MIT
import Carchive

/// libarchive の「コンパイルに使ったヘッダ」と「実行時にリンクされるライブラリ」の版。
///
/// ずれると「両方に存在するが意味・戻り値が変わった API」で静かに誤動作しうる。
/// 実例: ディレクトリエントリに対する `archive_read_data` の戻り値は
/// Homebrew 3.8.9 で -30、Apple 3.7.4 で -25 と異なった（2026-08-07 実測）。
///
/// ここに置く理由（G30）: **検査対象を 1 つのコンパイル単位に集約するため。**
/// 版はコンパイル時に焼き付くので、各テストターゲットが個別に `Carchive` を import すると
/// 「そのテストターゲットがどの版でコンパイルされたか」しか分からず、しかも陳腐化しうる面が
/// 検査するターゲットの数だけ増える。ここに集約すると、判定は **アプリが実際に積んでいる
/// `ArchiveAdapter` がどの版でコンパイルされたか**になり、他は実行時に読むだけになる。
///
/// 注意（2026-08-08 のブランチ全体レビューで実測訂正）: 当初この理由を
/// 「`Carchive` は product ではないので App から import できない」と書いていたが、**それは誤り**。
/// App のテストターゲットは `project.yml` を一切変えずに `import Carchive` できることが
/// 実測で確認されている。**この誤りを信じると「`project.yml` に依存を足すしかない」と
/// 判断してしまう** ―― プロジェクトの CLAUDE.md が「足すと壊れる」と明記している道である。
/// 集約の利点（上記）は import 可否とは無関係に成り立つ。
///
/// **この定数を別の場所へ動かすときは `Scripts/fetch-libarchive-headers.sh` の
/// `touch_version_test` も直すこと。** 判定を最新にする仕組みがこのファイルの位置に依存している
/// （G30 Task 1 で実際に一度壊れ、手作業の実験でしか気付けなかった）。
public enum LibarchiveVersion {
    /// コンパイル時に焼き付くヘッダの版（例 3007004 = 3.7.4）。
    public static let header = Int(ARCHIVE_VERSION_NUMBER)

    /// 実行時にリンクされるライブラリの版。Apple の `/usr/lib/libarchive.2.dylib` を指す。
    public static let runtime = Int(archive_version_number())

    /// 版が一致しないときに利用者へ出す文言。両方の版と、実行すべきコマンドを必ず含める。
    ///
    /// このチェックの価値は「ずれを検出すること」ではなく
    /// **「次に何をすればよいか即座に分かること」**にある。
    public static var mismatchMessage: String {
        """
        libarchive のヘッダ（\(header)）と実行時ライブラリ（\(runtime)）の版が違います。
        次を実行してヘッダを取得し直してください:
          ./Scripts/fetch-libarchive-headers.sh
        """
    }
}
