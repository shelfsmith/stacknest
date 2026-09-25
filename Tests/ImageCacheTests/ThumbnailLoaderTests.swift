// SPDX-License-Identifier: MIT
import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ImageCache

@Suite("ThumbnailLoader")
struct ThumbnailLoaderTests {
    /// Writes a tiny solid-color JPEG at <dir>/<id>/thumbnail.jpg.
    private func makeFixtureThumbnail(in dir: URL, id: Int, pixelSize: Int = 200) throws -> URL {
        let bookDir = dir.appendingPathComponent("\(id)")
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        let thumbURL = bookDir.appendingPathComponent("thumbnail.jpg")

        // Generate a tiny pixelSize x pixelSize gray JPEG via Core Graphics + ImageIO.
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGContext(
            data: nil,
            width: pixelSize, height: pixelSize,
            bitsPerComponent: 8, bytesPerRow: pixelSize * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        bitmap.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        let cgImage = bitmap.makeImage()!

        guard let dest = CGImageDestinationCreateWithURL(thumbURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "ThumbnailLoaderTests", code: 1)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ThumbnailLoaderTests", code: 2)
        }
        return thumbURL
    }

    @Test("Loads existing thumbnail at <dir>/<id>/thumbnail.jpg")
    func loadsExistingThumbnail() async throws {
        let tmpBundle = FileManager.default.temporaryDirectory.appendingPathComponent("loader-\(UUID().uuidString)")
        let tmpThumbnails = tmpBundle.appendingPathComponent("Thumbnails")
        try FileManager.default.createDirectory(at: tmpThumbnails, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBundle) }

        _ = try makeFixtureThumbnail(in: tmpThumbnails, id: 1, pixelSize: 200)

        let loader = ThumbnailLoader(bundleURL: tmpBundle)
        let img = await loader.thumbnail(for: 1, maxPixelSize: 100)
        #expect(img != nil)
        #expect((img?.width ?? 0) <= 100)
    }

    @Test("Returns nil for non-existent book id")
    func returnsNilForMissing() async throws {
        let tmpBundle = FileManager.default.temporaryDirectory.appendingPathComponent("loader-\(UUID().uuidString)")
        let tmpThumbnails = tmpBundle.appendingPathComponent("Thumbnails")
        try FileManager.default.createDirectory(at: tmpThumbnails, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBundle) }

        let loader = ThumbnailLoader(bundleURL: tmpBundle)
        let img = await loader.thumbnail(for: 9999, maxPixelSize: 100)
        #expect(img == nil)
    }

    /// G54-S3e（spec §2.6）: EXIF の向きの情報を持つ thumbnail.jpg は回転後の向きで返る（表紙の縮小が向きの情報を残しても正しく見える）。
    @Test("Applies the EXIF orientation of thumbnail.jpg")
    func appliesEXIFOrientation() async throws {
        let tmpBundle = FileManager.default.temporaryDirectory.appendingPathComponent("loader-\(UUID().uuidString)")
        let bookDir = tmpBundle.appendingPathComponent("Thumbnails").appendingPathComponent("1")
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBundle) }

        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let thumbURL = bookDir.appendingPathComponent("thumbnail.jpg")
        let dest = try #require(CGImageDestinationCreateWithURL(thumbURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: UInt32(6)] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let img = await ThumbnailLoader(bundleURL: tmpBundle).thumbnail(for: 1, maxPixelSize: 400)
        #expect(img?.width == 200)
        #expect(img?.height == 400)
    }

    @Test("purge(bookID:) covers every size used by callers")
    func purgeCoversAllCallerSizes() async throws {
        // Detail Pane (CoverImageView) は 600、grid BookCell は 400 を要求する。
        // purge() でこれらの size が確実に対象になることを保証する。
        // 新たな callsite を加えた際にここを壊して気付かせる回帰防止用。
        let used: Set<Int> = [400, 600]
        let supported = Set(ThumbnailLoader.supportedMaxPixelSizes)
        #expect(used.isSubset(of: supported),
                "ThumbnailLoader.supportedMaxPixelSizes must cover every maxPixelSize the app requests")
    }

    @Test("Cache hits on second call")
    func cacheHitsOnSecondCall() async throws {
        let tmpBundle = FileManager.default.temporaryDirectory.appendingPathComponent("loader-\(UUID().uuidString)")
        let tmpThumbnails = tmpBundle.appendingPathComponent("Thumbnails")
        try FileManager.default.createDirectory(at: tmpThumbnails, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBundle) }

        _ = try makeFixtureThumbnail(in: tmpThumbnails, id: 1, pixelSize: 200)

        let loader = ThumbnailLoader(bundleURL: tmpBundle)
        let first = await loader.thumbnail(for: 1, maxPixelSize: 50)
        let second = await loader.thumbnail(for: 1, maxPixelSize: 50)
        // Same in-memory CGImage instance — cached hit
        #expect(first === second)
    }
}
