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

    /// `count` 枚の小さな PNG 風のエントリ（中身は名前）を持つ zip を作る（`/usr/bin/zip`）。名前は 001.png… の順。
    private static func makeZip(pages count: Int, in directory: URL) throws -> (url: URL, names: [String]) {
        let source = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let names = (1...count).map { String(format: "%03d.png", $0) }
        for name in names { try Data("page:\(name)".utf8).write(to: source.appendingPathComponent(name)) }
        let zip = directory.appendingPathComponent("book.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-q", "-0", zip.path] + names
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return (zip, names)
    }

    private static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seq-skip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("並びを渡すと、遠くへ飛んだとき手前のページは取り出さず、目的の近く（skipWindow 枚）だけを取り出す")
    func farJumpSkipsEarlierPages() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (zip, names) = try Self.makeZip(pages: 40, in: dir)
        let ext = SequentialArchiveExtractor(url: zip, imageNames: Set(names), pageOrder: names)
        #expect(try await ext.data(forName: "036.png") == Data("page:036.png".utf8))
        let window = SequentialArchiveExtractor.skipWindow
        #expect(await ext.extractedCountForTesting == window + 1)
        #expect(await ext.skippedCountForTesting == 35 - window)
        // 近くのページ（窓の中）は取り出し済み。
        #expect(try await ext.data(forName: "030.png") == Data("page:030.png".utf8))
        #expect(await ext.extractedCountForTesting == window + 1)
        // 読み飛ばしたページを頼むと、頭から開き直し、そこまで通過するページを全部取り出す。開き直したので、読み飛ばしの
        // 記録は消える（残りはまたカーソルより前にある）。
        #expect(try await ext.data(forName: "002.png") == Data("page:002.png".utf8))
        #expect(await ext.extractedCountForTesting == window + 3)
        #expect(await ext.skippedCountForTesting == 0)
        // 開き直した後は前へ順に読んでも開き直さない（カーソルの続きから）。
        #expect(try await ext.data(forName: "001.png") == Data("page:001.png".utf8))
        #expect(try await ext.data(forName: "003.png") == Data("page:003.png".utf8))
        #expect(try await ext.data(forName: "010.png") == Data("page:010.png".utf8))
        #expect(await ext.skippedCountForTesting == 0)
        // また遠くへ飛ぶと、手前の取り出していないページ（011〜027）だけを読み飛ばす。
        #expect(try await ext.data(forName: "040.png") == Data("page:040.png".utf8))
        #expect(await ext.skippedCountForTesting == 17)
        #expect(try await ext.data(forName: "020.png") == Data("page:020.png".utf8))
    }

    /// `count` 枚のエントリを `/usr/bin/tar`（bsdtar）で `arguments` の形式の書庫にする（中身は名前）。
    private static func makeWithTar(pages count: Int, in directory: URL, fileName: String,
                                    arguments: [String]) throws -> (url: URL, names: [String]) {
        let source = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let names = (1...count).map { String(format: "%03d.png", $0) }
        for name in names { try Data("page:\(name)".utf8).write(to: source.appendingPathComponent(name)) }
        let out = directory.appendingPathComponent(fileName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.currentDirectoryURL = source
        process.arguments = arguments + [out.path] + names
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return (out, names)
    }

    @Test("読み飛ばしが位置を移すだけで済む形式（圧縮していない tar）でも読み飛ばす")
    func plainTarSkipsFarPages() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (tar, names) = try Self.makeWithTar(pages: 30, in: dir, fileName: "book.cbt", arguments: ["-cf"])
        let ext = SequentialArchiveExtractor(url: tar, imageNames: Set(names), pageOrder: names)
        #expect(try await ext.data(forName: "030.png") == Data("page:030.png".utf8))
        #expect(await ext.skippedCountForTesting == 29 - SequentialArchiveExtractor.skipWindow)
        #expect(try await ext.data(forName: "001.png") == Data("page:001.png".utf8))
    }

    @Test(
        "読み飛ばしにも伸長が要る形式（gzip の tar・7z）では読み飛ばさず、これまでどおり通過したページを全部取り出す",
        arguments: [("book.tgz", ["-czf"]), ("book.cb7", ["--format", "7zip", "-cf"])] as [(String, [String])])
    func compressedStreamsDoNotSkip(fileName: String, arguments: [String]) async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, names) = try Self.makeWithTar(pages: 30, in: dir, fileName: fileName, arguments: arguments)
        let ext = SequentialArchiveExtractor(url: url, imageNames: Set(names), allowsCompressedTar: true, pageOrder: names)
        #expect(try await ext.data(forName: "030.png") == Data("page:030.png".utf8))
        #expect(await ext.skippedCountForTesting == 0)
        #expect(await ext.extractedCountForTesting == 30)
    }

    @Test("読み飛ばしたページを頼んだときの読み直しでも、壊れていない限りページを返す（再試行の道は通常と同じ）")
    func skippedPageReadAfterFarJump() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (zip, names) = try Self.makeZip(pages: 30, in: dir)
        let ext = SequentialArchiveExtractor(url: zip, imageNames: Set(names), pageOrder: names)
        #expect(try await ext.data(forName: "030.png") == Data("page:030.png".utf8))
        // 読み飛ばしたページの後の、無い名前（差し替え後に消えたページなど）は、読み直しても無ければ noImageEntry。
        await #expect(throws: ArchiveAdapterError.self) { try await ext.data(forName: "missing.png") }
        #expect(try await ext.data(forName: "005.png") == Data("page:005.png".utf8))
    }

    @Test("並びを渡さなければ、これまでどおり通過したページを全部取り出す")
    func withoutPageOrderEverythingPassedIsExtracted() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (zip, names) = try Self.makeZip(pages: 20, in: dir)
        let ext = SequentialArchiveExtractor(url: zip, imageNames: Set(names))
        #expect(try await ext.data(forName: "018.png") == Data("page:018.png".utf8))
        #expect(await ext.extractedCountForTesting == 18)
        #expect(await ext.skippedCountForTesting == 0)
    }

    @Test("前から順に読むときは何も読み飛ばさない(窓の中を進むだけ)")
    func sequentialReadingSkipsNothing() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (zip, names) = try Self.makeZip(pages: 30, in: dir)
        let ext = SequentialArchiveExtractor(url: zip, imageNames: Set(names), pageOrder: names)
        for name in names { #expect(try await ext.data(forName: name) == Data("page:\(name)".utf8)) }
        #expect(await ext.skippedCountForTesting == 0)
        #expect(await ext.extractedCountForTesting == 30)
    }
}
