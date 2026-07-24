// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

/// 展開後サイズ上限の純関数の境界値テスト（decompression-bomb / OOM 対策）。
@Suite("ArchiveEntrySizeLimit")
struct ArchiveEntrySizeLimitTests {
    @Test func acceptsSizeAtOrBelowCap() {
        #expect(ArchiveEntrySizeLimit.shouldReject(size: 0, limit: 100) == false)
        #expect(ArchiveEntrySizeLimit.shouldReject(size: 100, limit: 100) == false)
        #expect(ArchiveEntrySizeLimit.shouldReject(size: 99, limit: 100) == false)
    }

    @Test func rejectsSizeAboveCap() {
        #expect(ArchiveEntrySizeLimit.shouldReject(size: 101, limit: 100) == true)
        #expect(ArchiveEntrySizeLimit.shouldReject(size: Int.max, limit: 100) == true)
    }

    @Test func defaultLimitIsGenerousButBounded() {
        // 通常のカバー/ページ画像（数十MB級）は通過する。
        #expect(ArchiveEntrySizeLimit.shouldReject(size: 50 * 1024 * 1024) == false)
        // 宣言サイズが上限を超えるものは拒否される。
        #expect(ArchiveEntrySizeLimit.shouldReject(size: ArchiveEntrySizeLimit.maxEntryBytes + 1) == true)
    }
}
