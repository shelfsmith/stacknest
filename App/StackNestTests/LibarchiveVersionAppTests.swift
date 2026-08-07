// SPDX-License-Identifier: MIT
import Testing
import ArchiveAdapter

/// G30: 版一致チェックを **xcodebuild 経路**でも走らせる。
///
/// G28 で入れた `swift test` 側の検査だけでは、**このフェーズ群の発端である事故**
/// ―― Homebrew が libarchive を更新してプリコンパイル済みモジュールが陳腐化し、
/// **App のビルドが静かに壊れた** ―― を捕まえられなかった。
/// `swift test` は App ターゲットを一切見ないため、Xcode 側でのみ起きるずれは
/// こちらでしか守れない。
///
/// SPM 側と同じ判定を、同じ `ArchiveAdapter.LibarchiveVersion` の値で行う。
///
/// **陳腐化への対処（2026-08-08 実測・G30 Task 2 Step 5）**: xcodebuild のインクリメンタル
/// ビルドは **SwiftPM と同じ意味で陳腐化する** ―― `vendor/` の中身だけを版ずれさせて
/// touch を一切行わずに `xcodebuild test` を再実行すると、このテストは古い（一致した）
/// 判定のまま **偽の PASS** を返した。判定が現在化するのは
/// `Scripts/fetch-libarchive-headers.sh` が既に行っている `Carchive.h` と
/// `Sources/ArchiveAdapter/LibarchiveVersion.swift` の touch のおかげであり
/// （実際、`touch Carchive.h LibarchiveVersion.swift` の後に再実行すると正しく FAIL した）、
/// 「xcodebuild だから安全」という理由ではない。このテストソース自体を touch 対象に
/// 加える必要がないのは、判定値が `ArchiveAdapter.LibarchiveVersion`（= 上記 2 ファイルの
/// touch で必ず現在化する）に一本化されており、このファイルを含めどの利用者も
/// 実行時にそこを読むだけだからである。
///
/// **検証時の落とし穴**: `vendor/` ディレクトリを丸ごと退避すると、版ずれではなく
/// **ビルドエラー**になる（`malformed or corrupted AST file: could not find file
/// .../vendor/archive_entry.h referenced by AST file ... Carchive-....pcm` ―― キャッシュ
/// 済み PCM が存在しないファイルを参照した状態）。これは版ずれの検査にならない。
/// 版ずれを再現するには `vendor/` は**そのまま残し**、`archive.h` と `archive_entry.h`
/// の**両方**の `ARCHIVE_VERSION_NUMBER` を書き換えたうえで、実効値を
/// `clang -I Sources/ArchiveAdapter/Carchive -E -dM -x c /dev/null
/// -include Sources/ArchiveAdapter/Carchive/Carchive.h | grep 'ARCHIVE_VERSION_NUMBER '`
/// で確認すること。
@Suite("libarchive の版一致（App ターゲット / G30）")
struct LibarchiveVersionAppTests {
    @Test("ヘッダと実行時ライブラリの版が一致する（xcodebuild 経路）")
    func headerMatchesRuntime() {
        #expect(LibarchiveVersion.header == LibarchiveVersion.runtime,
                "\(LibarchiveVersion.mismatchMessage)")
    }
}
