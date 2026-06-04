// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// B19 (Phase 2.5h): cover の JPEG Data を `maxPixelSize` で resize したものに変換する純粋関数。
/// `maxPixelSize` 以下の入力はそのまま返す (品質維持)。空 Data は空のまま返す。
public enum CoverImageResizer {
    public static func resizeJPEG(_ data: Data, maxPixelSize: Int) -> Data {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return data
        }
        // 既存 size 計測
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, opts as CFDictionary) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return data  // 計測できない場合は無加工で返す
        }
        if max(w, h) <= maxPixelSize {
            return data
        }
        // resize 書き出し
        let writeOpts: [CFString: Any] = [
            kCGImageDestinationImageMaxPixelSize: maxPixelSize,
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutable, UTType.jpeg.identifier as CFString, 1, nil) else {
            return data
        }
        CGImageDestinationAddImageFromSource(dest, source, 0, writeOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return data
        }
        return mutable as Data
    }
}
