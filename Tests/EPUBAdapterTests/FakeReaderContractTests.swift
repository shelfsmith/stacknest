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
    /// 全 itemref の XHTML が「`<image` または `<img` を 1 つだけ含み、タグを除いた本文が空」なら
    /// 画像本とみなす。1 つでも当てはまらなければ nil（偽物を甘くしない: 契約テストが偽物で
    /// 通ることを確かめるための実装であって、判定を緩めてはいけない）。
    func openImageBook(url: URL) async throws -> (any EPUBImageBookReading)? {
        guard let opf = try? Self.unzip(url, "OEBPS/content.opf"), !opf.isEmpty else {
            throw EPUBAdapterError.cannotOpen("no opf")
        }
        let dir: EPUBReadingDirection = opf.contains(#"page-progression-direction="rtl""#) ? .rtl : .ltr

        let itemrefs = Self.matches(#"<itemref\b[^>]*>"#, in: opf)
        guard !itemrefs.isEmpty else { return nil }

        var hrefsByID: [String: String] = [:]
        for item in Self.matches(#"<item\b[^>]*>"#, in: opf) {
            guard let id = Self.attribute("id", in: item), let href = Self.attribute("href", in: item) else { continue }
            hrefsByID[id] = href
        }

        var pages: [Data] = []
        var spreads: [EPUBPageSpread] = []
        for itemref in itemrefs {
            guard let idref = Self.attribute("idref", in: itemref), let href = hrefsByID[idref] else { return nil }
            guard let xhtml = try? Self.unzip(url, "OEBPS/\(href)") else { return nil }
            guard let imageHref = Self.singleImageHref(in: xhtml) else { return nil }
            guard let imageData = try? Self.unzipData(url, "OEBPS/\(imageHref)"), !imageData.isEmpty else { return nil }
            pages.append(imageData)

            let spread: EPUBPageSpread
            if itemref.contains("page-spread-left") { spread = .left }
            else if itemref.contains("page-spread-right") { spread = .right }
            else if itemref.contains("page-spread-center") { spread = .center }
            else { spread = .none }
            spreads.append(spread)
        }
        return FakeImageBook(pages: pages, readingDirection: dir, spreads: spreads)
    }

    /// XHTML の `<body>` に画像タグ（`<image` または `<img`）が 1 つだけあり、全タグを取り除いた
    /// テキストが空（＝画像以外のコンテンツが無い）なら、その画像の href を返す。
    private static func singleImageHref(in xhtml: String) -> String? {
        let imageTags = Self.matches(#"<image\b[^>]*>"#, in: xhtml) + Self.matches(#"<img\b[^>]*>"#, in: xhtml)
        guard imageTags.count == 1, let tag = imageTags.first else { return nil }
        guard let href = Self.attribute("xlink:href", in: tag) ?? Self.attribute("href", in: tag) ?? Self.attribute("src", in: tag) else { return nil }

        guard let bodyRange = xhtml.range(of: "<body"),
              let bodyOpenEnd = xhtml.range(of: ">", range: bodyRange.upperBound..<xhtml.endIndex),
              let bodyCloseStart = xhtml.range(of: "</body>", range: bodyOpenEnd.upperBound..<xhtml.endIndex) else { return nil }
        var body = String(xhtml[bodyOpenEnd.upperBound..<bodyCloseStart.lowerBound])
        while let tagRange = body.range(of: #"<[^>]*>"#, options: .regularExpression) {
            body.removeSubrange(tagRange)
        }
        guard body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return href
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: name))=\"([^\"]*)\"") else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
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

/// `UnzipFakeReader.openImageBook` が返す handle。EPUB を開いた時点で全ページの画像データを
/// 抱えており、以降の `imageData(at:)` はメモリ上の配列を返すだけ（zip の再展開はしない）。
private final class FakeImageBook: EPUBImageBookReading {
    let pages: [Data]
    let readingDirection: EPUBReadingDirection
    let spreads: [EPUBPageSpread]
    init(pages: [Data], readingDirection: EPUBReadingDirection, spreads: [EPUBPageSpread]) {
        self.pages = pages
        self.readingDirection = readingDirection
        self.spreads = spreads
    }
    var pageCount: Int { pages.count }
    func imageData(at index: Int) async throws -> Data {
        guard pages.indices.contains(index) else {
            throw EPUBAdapterError.cannotOpen("page index out of range: \(index)")
        }
        return pages[index]
    }
}

@Suite("契約テストそのものの妥当性")
struct FakeReaderContractTests {
    @Test("正しい偽物は契約テストを通る")
    func fakePasses() async throws {
        try await EPUBReadingContract.run(UnzipFakeReader())
    }
}
