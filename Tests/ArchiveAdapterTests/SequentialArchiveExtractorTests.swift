// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

/// G18 C5: 開きっぱなし順方向リーダーの正しさ（前方 1 パス・後方はキャッシュ・既存経路と一致）。
@Suite("SequentialArchiveExtractor")
struct SequentialArchiveExtractorTests {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ArchiveAdapterTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func imageNames() async throws -> [String] {
        try await LibarchiveCoverExtractor().listImageEntries(in: fixture("three_pages.zip"))
    }

    @Test func forwardReadsReturnCorrectPngBytes() async throws {
        let names = try await imageNames()
        #expect(names == ["p1.png", "p2.png", "p10.png"])
        let ext = SequentialArchiveExtractor(url: fixture("three_pages.zip"), imageNames: Set(names))
        let pngSig = Data([0x89, 0x50, 0x4E, 0x47])
        for name in names {   // 前方順に読む（カーソルを進めるだけ）
            let data = try await ext.data(forName: name)
            #expect(data.count > 0)
            #expect(data.prefix(4) == pngSig)
        }
    }

    @Test func backwardReadHitsCacheAndStaysCorrect() async throws {
        let names = try await imageNames()
        let ext = SequentialArchiveExtractor(url: fixture("three_pages.zip"), imageNames: Set(names))
        // 末尾まで前方に進めてから、先頭へ戻る（＝通過済みはキャッシュから返る・再オープン不要）。
        let last = try await ext.data(forName: "p10.png")
        let firstAgain = try await ext.data(forName: "p1.png")
        let secondAgain = try await ext.data(forName: "p2.png")
        // 既存の stateless 経路（正解）とバイト一致することを確認する。
        let ref = LibarchiveCoverExtractor()
        let refFirst = try await ref.imageData(in: fixture("three_pages.zip"), entryName: "p1.png")
        let refSecond = try await ref.imageData(in: fixture("three_pages.zip"), entryName: "p2.png")
        let refLast = try await ref.imageData(in: fixture("three_pages.zip"), entryName: "p10.png")
        #expect(firstAgain == refFirst)
        #expect(secondAgain == refSecond)
        #expect(last == refLast)
    }

    @Test func randomAccessJumpThenNeighborsAllCorrect() async throws {
        let names = try await imageNames()
        let ext = SequentialArchiveExtractor(url: fixture("three_pages.zip"), imageNames: Set(names))
        let ref = LibarchiveCoverExtractor()
        // 途中から要求（前方ストリームで p1 も通過キャッシュされる）→ 続けて前後どちらも一致。
        for name in ["p2.png", "p1.png", "p10.png", "p2.png"] {
            let got = try await ext.data(forName: name)
            let want = try await ref.imageData(in: fixture("three_pages.zip"), entryName: name)
            #expect(got == want, "\(name) mismatch")
        }
    }

    @Test func missingEntryThrows() async throws {
        let names = try await imageNames()
        let ext = SequentialArchiveExtractor(url: fixture("three_pages.zip"), imageNames: Set(names))
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await ext.data(forName: "nonexistent.png")
        }
    }

    /// セキュリティ: 逐次読み取りの累積サイズが上限を超えたら OOM を招く前に throw する
    /// （decompression-bomb 対策）。実物の巨大アーカイブは作らず、注入した小さい上限で検証する。
    @Test func entryExceedingCapThrowsInsteadOfUnboundedGrowth() async throws {
        let names = try await imageNames()
        // p1.png は数十バイトの 1x1 PNG なので、上限 1 byte なら必ず超過する。
        let ext = SequentialArchiveExtractor(url: fixture("three_pages.zip"), imageNames: Set(names), maxEntryBytes: 1)
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await ext.data(forName: "p1.png")
        }
    }

    /// 上限を十分大きく取れば、通常サイズのページはこれまで通り抽出できる（回帰なし）。
    @Test func entryWithinCapStillExtractsNormally() async throws {
        let names = try await imageNames()
        let ext = SequentialArchiveExtractor(url: fixture("three_pages.zip"), imageNames: Set(names), maxEntryBytes: ArchiveEntrySizeLimit.maxEntryBytes)
        let data = try await ext.data(forName: "p1.png")
        #expect(data.count > 0)
    }
}
