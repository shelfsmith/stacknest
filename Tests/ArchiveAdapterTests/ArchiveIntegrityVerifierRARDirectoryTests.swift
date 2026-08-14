// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

/// RAR のディレクトリエントリは名前に末尾 "/" を付けない（ZIP と違う）。
/// 名前規約だけでディレクトリを判定すると、ディレクトリエントリのデータを読もうとして
/// 負値が返り、**破損と誤判定**する ―― G27b の実機 smoke で見つかった実バグ。
///
/// ## 検体をコミットしている理由（G36）
///
/// 以前は `rar` CLI で実行時に生成していたが、**`rar` は proprietary で
/// GitHub Actions のランナーに無い**ため CI ではテストごとスキップされ、
/// **RAR 経路が完全に無検証**だった。検体は自作の内容なのでコミットできる。
/// 再生成手順は `Tests/Fixtures/build_rar_fixtures.sh`。
struct ArchiveIntegrityVerifierRARDirectoryTests {

    private func fixture(_ name: String) -> URL {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()  // ArchiveAdapterTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    @Test("末尾スラッシュの無いディレクトリエントリを破損扱いしない")
    func rarDirectoryEntryWithoutTrailingSlashIsNotFlaggedAsDamaged() throws {
        let url = fixture("rar5-with-directory.rar")

        let result = try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: { false })

        #expect(result.badEntries.isEmpty)
        #expect(result.truncated == false)
        // ディレクトリ自身(somedir)はエントリ数に含めない。top.png / somedir/1.png の 2 件だけ。
        #expect(result.entryCount == 2)
        #expect(!result.badEntries.contains("somedir"))
    }

    @Test("本当に壊れたエントリは検出する")
    func genuinelyCorruptedRAREntryIsStillDetected() throws {
        let url = fixture("rar5-corrupted-entry.rar")

        let result = try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: { false })

        #expect(result.badEntries == ["big.txt"])
        #expect(result.truncated == false)
        #expect(result.entryCount == 1)
    }
}
