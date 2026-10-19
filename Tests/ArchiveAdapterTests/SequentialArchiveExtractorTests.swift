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
        try await LibarchiveCoverExtractor().listImageEntries(in: fixture("three_pages.zip")).names
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

    /// 無圧縮の zip（`/usr/bin/zip -0`）を作り、`corrupt` のエントリの中身の 1 バイトを書き換える（CRC が合わなくなる）。
    private static func makeZipWithBadEntry(pages count: Int, corrupt: Int, in directory: URL) throws -> (url: URL, names: [String]) {
        try makeZipWithBadEntries(pages: count, corrupt: [corrupt], in: directory)
    }

    private static func makeZipWithBadEntries(pages count: Int, corrupt: Set<Int>, in directory: URL) throws -> (url: URL, names: [String]) {
        let source = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let names = (1...count).map { String(format: "%03d.png", $0) }
        for name in names { try Data(String(repeating: "page:\(name);", count: 20).utf8).write(to: source.appendingPathComponent(name)) }
        let zip = directory.appendingPathComponent("book.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-q", "-0", zip.path] + names
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        // ローカルヘッダを先頭から辿り、corrupt 番目（1 始まり）のエントリの中身の真ん中を書き換える。
        var bytes = [UInt8](try Data(contentsOf: zip))
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        var offset = 0
        for index in 1...count {
            try #require(u32(offset) == 0x0403_4B50)
            let size = u32(offset + 18), nameLength = u16(offset + 26), extraLength = u16(offset + 28)
            let dataStart = offset + 30 + nameLength + extraLength
            if corrupt.contains(index) { bytes[dataStart + size / 2] ^= 0xFF }
            offset = dataStart + size
        }
        try Data(bytes).write(to: zip)
        return (zip, names)
    }

    @Test("途中のエントリの中身が壊れていても、それより後のページは読める（壊れたページだけが失敗する）")
    func laterPagesSurviveABadEntry() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seq-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (zip, names) = try Self.makeZipWithBadEntry(pages: 6, corrupt: 3, in: dir)
        let ext = SequentialArchiveExtractor(url: zip, imageNames: Set(names))
        let page5 = try await ext.data(forName: "005.png")
        #expect(page5 == Data(String(repeating: "page:005.png;", count: 20).utf8))
        #expect(try await ext.data(forName: "001.png") == Data(String(repeating: "page:001.png;", count: 20).utf8))
        await #expect(throws: ArchiveAdapterError.self) { _ = try await ext.data(forName: "003.png") }
        #expect(try await ext.data(forName: "006.png") == Data(String(repeating: "page:006.png;", count: 20).utf8))
    }

    private static func page(_ name: String) -> Data { Data(String(repeating: "page:\(name);", count: 20).utf8) }

    @Test("壊れたエントリはその場で読み飛ばして先へ進み（開き直さない）、壊れたページを頼み直すと、残りを取り出さずに頭から開き直す")
    func badEntriesAreSkippedInPlaceAndRetriedFromTheStart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seq-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (zip, names) = try Self.makeZipWithBadEntries(pages: 10, corrupt: [3, 5], in: dir)
        let ext = SequentialArchiveExtractor(url: zip, imageNames: Set(names))
        #expect(try await ext.data(forName: "007.png") == Self.page("007.png"))
        #expect(await ext.resetCountForTesting == 0, "CRC の不一致はハンドルを壊さないので、開き直さない")
        #expect(await ext.extractedCountForTesting == 5)
        // 壊れたページ: 1 回目は頭から読み直して（カーソルの先にあるので）失敗、そこで止まり残りは取り出さない。
        await #expect(throws: ArchiveAdapterError.self) { _ = try await ext.data(forName: "003.png") }
        #expect(await ext.resetCountForTesting == 1)
        #expect(await ext.extractedCountForTesting == 5)
        // もう一度頼んでも、開き直しは 1 回だけ（同じ失敗を 2 度は繰り返さない）。
        await #expect(throws: ArchiveAdapterError.self) { _ = try await ext.data(forName: "003.png") }
        #expect(await ext.resetCountForTesting == 2)
        // 後のページは読める。
        #expect(try await ext.data(forName: "010.png") == Self.page("010.png"))
        #expect(try await ext.data(forName: "004.png") == Self.page("004.png"))
    }
}
