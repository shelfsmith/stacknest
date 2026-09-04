// SPDX-License-Identifier: MIT
import Testing
import Foundation
import EPUBAdapter
import EPUBAdapterTestSupport

/// 契約テストが「正しく作られた実装」で通ることを、Washi とは無関係に確かめる。
/// この偽物は zip を `/usr/bin/unzip -p` で覗いて content.opf を正規表現で読む。
struct UnzipFakeReader: EPUBReading {
    func open(url: URL) async throws -> EPUBBookInfo {
        guard let opf = try? Self.unzip(url, "OEBPS/content.opf"), !opf.isEmpty else {
            throw EPUBAdapterError.cannotOpen("no opf")
        }
        func tag(_ name: String) -> String? {
            guard let r = opf.range(of: "<\(name)>"), let e = opf.range(of: "</\(name)>", range: r.upperBound..<opf.endIndex) else { return nil }
            return String(opf[r.upperBound..<e.lowerBound])
        }
        let dir: EPUBReadingDirection = opf.contains(#"page-progression-direction="rtl""#) ? .rtl : .ltr
        return EPUBBookInfo(title: tag("dc:title"), author: tag("dc:creator"), language: tag("dc:language"), readingDirection: dir)
    }
    func coverImageData(url: URL, maxPixelSize: Int) async throws -> Data? {
        guard let opf = try? Self.unzip(url, "OEBPS/content.opf"), !opf.isEmpty else { throw EPUBAdapterError.cannotOpen("no opf") }
        guard opf.contains("cover-image") else { return nil }
        return try Self.unzipData(url, "OEBPS/cover.png")
    }
    // G48-2b Task 2 で本実装する。ここでは契約に適合させるためだけの仮実装。
    func openImageBook(url: URL) async throws -> (any EPUBImageBookReading)? {
        nil
    }
    private static func unzip(_ url: URL, _ entry: String) throws -> String {
        String(decoding: try unzipData(url, entry), as: UTF8.self)
    }
    private static func unzipData(_ url: URL, _ entry: String) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, entry]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return d
    }
}

@Suite("契約テストそのものの妥当性")
struct FakeReaderContractTests {
    @Test("正しい偽物は契約テストを通る")
    func fakePasses() async throws {
        try await EPUBReadingContract.run(UnzipFakeReader())
    }
}
