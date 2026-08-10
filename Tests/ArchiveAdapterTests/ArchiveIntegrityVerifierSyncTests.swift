// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

/// G34a Task A1: `verifySync` が「開始時点で既に中断されている」を取りこぼさないことを確認する。
///
/// `ArchiveIntegrityVerifierTests` / `ArchiveIntegrityVerifierRARDirectoryTests` は
/// G34a で async 版から `verifySync` へ移行済みで、CRC 判定・破損・非アーカイブ・
/// 途中中断・絶対パス秘匿はそちらが引き続き守っている。**ここには重複を置かず**、
/// 同期化にあたって新しく効くようになった不変条件だけを書く。
struct ArchiveIntegrityVerifierSyncTests {

    /// ★ 走査は 1 冊ごとに新しい `verifySync` を呼ぶ。したがって「前の冊の途中で中断された」状態は
    /// **次の冊の最初のエントリ確認**で拾われなければならない。ここが効かないと、中断してから
    /// 実際に止まるまでに残り全冊（数万冊 × 数秒）を読み切ってしまう。
    ///
    /// G34a では中断判定が actor 越しの async から `CancellationMirror` 経由の同期フラグへ変わったため、
    /// 「ループに入る前に一度は評価される」ことを検証で固定しておく。
    @Test
    func alreadyCancelledReturnsTruncatedWithoutReadingAnything() throws {
        let entries = (1...20).map { ("\($0).png", DamagedArchiveTests.tinyPNG) }
        let zip = DamagedArchiveTests.makeStoredZip(entries)
        let url = try ArchiveIntegrityVerifierTests.writeTemp(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: { true })

        #expect(result.truncated == true)
        #expect(result.entryCount == 0)
        #expect(result.imageCount == 0)
        #expect(result.badEntries.isEmpty)
    }

    /// 中断判定は**エントリ単位**で見続ける（冊の途中で中断できる）。
    /// 移行前後で粒度が変わっていないことの確認。
    @Test
    func cancellationPartwayStopsWithinTheSameBook() throws {
        let entries = (1...20).map { ("\($0).png", DamagedArchiveTests.tinyPNG) }
        let zip = DamagedArchiveTests.makeStoredZip(entries)
        let url = try ArchiveIntegrityVerifierTests.writeTemp(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        var calls = 0
        let result = try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: {
            calls += 1
            return calls > 3
        })

        #expect(result.truncated == true)
        #expect(result.entryCount > 0)
        #expect(result.entryCount < 20)
    }
}
