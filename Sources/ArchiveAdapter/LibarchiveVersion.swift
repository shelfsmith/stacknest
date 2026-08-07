// SPDX-License-Identifier: MIT
import Carchive

/// libarchive の「コンパイルに使ったヘッダ」と「実行時にリンクされるライブラリ」の版。
///
/// ずれると「両方に存在するが意味・戻り値が変わった API」で静かに誤動作しうる。
/// 実例: ディレクトリエントリに対する `archive_read_data` の戻り値は
/// Homebrew 3.8.9 で -30、Apple 3.7.4 で -25 と異なった（2026-08-07 実測）。
///
/// ここに置く理由（G30）: `Carchive` は SPM の product ではないため App ターゲットから
/// import できない。`ArchiveAdapter` は product であり App の依存にも入っているので、
/// **SPM と Xcode の両方のテストから同じ値を見られる**。
/// 副次的に、検査対象が「テストターゲット自身のコンパイル結果」ではなく
/// **アプリが実際に積んでいる ArchiveAdapter がどの版でコンパイルされたか**になる。
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
