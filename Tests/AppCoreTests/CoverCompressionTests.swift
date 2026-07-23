// SPDX-License-Identifier: MIT
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import AppCore
@testable import LibraryStore
import StackroomFormat

@Suite("CoverCompression")
struct CoverCompressionTests {
    @Test func skipsExternalCovers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc_\(UUID().uuidString)")
        let bundle = dir.appendingPathComponent("lib.stacknest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let db = try Database.openFile(at: bundle.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        // 外部表紙の本（source も存在しない）＋ source missing の内部表紙本 → いずれも更新 0
        _ = try db.insertBookReturningID(BookRecord(
            id: 0, title: "ext", path: "/nonexistent/a.zip", coverImageName: CoverSource.externalSentinel,
            dateAdded: Date()))
        _ = try db.insertBookReturningID(BookRecord(
            id: 0, title: "missing-source", path: "/nonexistent/b.zip", coverImageName: nil,
            dateAdded: Date()))
        var progressCalls = 0
        let updated = try await CoverCompression.compressOversizedCovers(
            db: db, bundleURL: bundle, progress: { _, _ in progressCalls += 1 }, isCancelled: { false })
        #expect(updated == 0)          // 外部表紙 or source 不在は圧縮しない
        #expect(progressCalls == 2)    // progress は全件走査で呼ばれる
    }

    /// G22 #3: 単独画像本（.jpg 1 枚が book の path）の thumbnail が compressOversizedCovers で
    /// 再生成されることを確認する。旧実装（PDF/アーカイブ二分岐）は単独画像を素通りさせ thumbnail は
    /// 不変だったが、CoverRefresher.extractCoverData 一本化後は実ソースから作り直される。
    @Test func regeneratesStandaloneImageBookCover() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc_\(UUID().uuidString)")
        let bundle = dir.appendingPathComponent("lib.stacknest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let db = try Database.openFile(at: bundle.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()

        // 単独画像本: source は実ファイルとして存在する 1200px cap 超の JPEG。
        let sourceDir = dir.appendingPathComponent("book")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let sourceURL = sourceDir.appendingPathComponent("cover.jpg")
        try makeJPEG(width: 2000, height: 3000).write(to: sourceURL)

        let bookID = try db.insertBookReturningID(BookRecord(
            id: 0, title: "standalone-image", path: sourceURL.path, coverImageName: nil,
            dateAdded: Date()))

        // 意図的に「古い」thumbnail を先に置く（source とは別内容の JPEG）。
        let thumbURL = bundle.appendingPathComponent("Thumbnails/\(bookID)/thumbnail.jpg")
        try FileManager.default.createDirectory(
            at: thumbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldThumbData = try makeJPEG(width: 2000, height: 3000)
        try oldThumbData.write(to: thumbURL)

        let updated = try await CoverCompression.compressOversizedCovers(
            db: db, bundleURL: bundle, progress: { _, _ in }, isCancelled: { false })

        let newThumbData = try Data(contentsOf: thumbURL)
        // 実ソースから再生成されていれば、1200px cap 適用後のデータは旧 thumbnail と一致しない。
        #expect(newThumbData != oldThumbData)
        let dims = dimensions(of: newThumbData)
        #expect(dims != nil)
        #expect(max(dims?.0 ?? .max, dims?.1 ?? .max) <= 1200)
        #expect(updated == 1)
    }

    /// 指定サイズの単色 JPEG Data を生成する helper（CoverRefresherResizeTests と同じ手法）。
    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let mutable = NSMutableData()
        let dest = CGImageDestinationCreateWithData(mutable, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "test", code: 1)
        }
        return mutable as Data
    }

    private func dimensions(of data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return (img.width, img.height)
    }
}
