// SPDX-License-Identifier: MIT
//
// Two-tier thumbnail loader (in-memory only in Spec 2; on-disk thumbnail.jpg
// already exists at <dir>/<id>/thumbnail.jpg, so no separate disk cache is needed).

import Foundation
import CoreGraphics
import ImageIO

public actor ThumbnailLoader {
    /// アプリが `thumbnail(for:maxPixelSize:)` に渡す maxPixelSize の一覧。
    /// purge(bookID:) はこのリストを使って既存キャッシュを掃除する。
    /// 新たに別 size を要求する callsite を追加する場合はここにも追記すること。
    /// 現用: BookCell=400, DetailPaneView CoverImageView=600。
    public static let supportedMaxPixelSizes: [Int] = [400, 600]

    private let thumbnailsDirectoryURL: URL
    private let cache: NSCache<NSString, CGImage>

    public init(bundleURL: URL, costLimitMB: Int = 100) {
        self.thumbnailsDirectoryURL = bundleURL.appending(path: "Thumbnails")
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = costLimitMB * 1024 * 1024
        self.cache = cache
    }

    /// Returns a downsampled thumbnail for `bookID`, or `nil` if the source file is missing/unreadable.
    /// `maxPixelSize` is the maximum dimension (width or height) of the returned image.
    ///
    /// Note: CGImageSourceCreateWithURL has an internal URL-based cache that can return stale
    /// content after a cover image is replaced on disk. We use Data-based loading instead
    /// (CGImageSourceCreateWithData) to completely bypass that cache layer.
    public func thumbnail(for bookID: Int, maxPixelSize: Int) -> CGImage? {
        let key = NSString(string: "\(bookID):\(maxPixelSize)")
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let url = thumbnailsDirectoryURL
            .appendingPathComponent("\(bookID)")
            .appendingPathComponent("thumbnail.jpg")
        // 🔧 Fix A: Data-based read to bypass CGImageSource URL-level cache.
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        let cost = cgImage.bytesPerRow * cgImage.height
        cache.setObject(cgImage, forKey: key, cost: cost)
        return cgImage
    }

    /// Removes the in-memory cache entries for a single book.
    /// NSCache does not expose key enumeration, so we enumerate `supportedMaxPixelSizes`
    /// — the single source of truth for sizes the app actually requests.
    public func purge(bookID: Int) {
        for size in Self.supportedMaxPixelSizes {
            let key = NSString(string: "\(bookID):\(size)")
            cache.removeObject(forKey: key)
        }
    }

    /// Clears the entire in-memory cache (used on library close / bulk operations).
    public func purge() {
        cache.removeAllObjects()
    }
}
