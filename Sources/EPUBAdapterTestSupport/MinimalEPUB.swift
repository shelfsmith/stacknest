// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// テスト用の最小 EPUB 3 をその場で作る。契約テストと Washi のテストが共有する。
public enum MinimalEPUB {
    /// - withCover: true なら 8x12 の PNG を表紙として manifest に `properties="cover-image"` で入れる
    /// - 戻り値: 生成した `.epub` の URL
    public static func make(in dir: URL, title: String, author: String?, withCover: Bool) throws -> URL {
        let work = dir.appendingPathComponent("epub-src-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: work.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)

        try "application/epub+zip".write(to: work.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: work.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)

        let creator = author.map { "<dc:creator>\($0)</dc:creator>" } ?? ""
        let coverItem = withCover ? #"<item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>"# : ""
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(title)</dc:title>
            \(creator)
            <dc:language>ja</dc:language>
            <meta property="dcterms:modified">2026-09-02T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="p1" href="p1.xhtml" media-type="application/xhtml+xml"/>
            \(coverItem)
          </manifest>
          <spine page-progression-direction="rtl"><itemref idref="p1"/></spine>
        </package>
        """.write(to: work.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)
        let xhtml = { (body: String) in
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>x</title></head><body>\(body)</body></html>
            """
        }
        try xhtml(#"<nav epub:type="toc"><ol><li><a href="p1.xhtml">1</a></li></ol></nav>"#)
            .write(to: work.appendingPathComponent("OEBPS/nav.xhtml"), atomically: true, encoding: .utf8)
        try xhtml("<p>本文</p>").write(to: work.appendingPathComponent("OEBPS/p1.xhtml"), atomically: true, encoding: .utf8)
        if withCover {
            try pngData(width: 8, height: 12).write(to: work.appendingPathComponent("OEBPS/cover.png"))
        }

        let out = dir.appendingPathComponent("book-\(UUID().uuidString).epub")
        try zip(["-X", "-0", out.path, "mimetype"], cwd: work)
        try zip(["-X", "-r", "-9", "-D", out.path, "META-INF", "OEBPS"], cwd: work)
        try? fm.removeItem(at: work)
        return out
    }

    private static func zip(_ args: [String], cwd: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "MinimalEPUB", code: Int(p.terminationStatus)) }
    }

    private static func pngData(width: Int, height: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let img = { ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height)); return ctx.makeImage() }()
        else { throw NSError(domain: "MinimalEPUB", code: 1) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw NSError(domain: "MinimalEPUB", code: 2) }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "MinimalEPUB", code: 3) }
        return data as Data
    }
}
