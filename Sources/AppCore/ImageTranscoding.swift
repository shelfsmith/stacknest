// SPDX-License-Identifier: MIT
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 画像バイト列の縮小・再圧縮の抽象（4.1c）。
/// LibraryServer はこの protocol 経由で注入を受ける（ImageIO 直接 import を避ける）。
public protocol ImageTranscoding: Sendable {
    /// 画像を最大幅 `maxWidth` px に縮小して返す。
    /// 縮小不要（元幅 ≤ maxWidth）・非画像・失敗時は元データをそのまま返す（決して throw しない）。
    func scaled(_ data: Data, maxWidth: Int) -> Data
}

/// 縮小しない既定実装（Docker v1・テスト用）。
public struct PassthroughTranscoder: ImageTranscoding {
    public init() {}
    public func scaled(_ data: Data, maxWidth: Int) -> Data { data }
}

/// ImageIO による縮小・JPEG 再圧縮（Mac 実装）。
public struct ImageIOTranscoder: ImageTranscoding {
    public var quality: Double
    public init(quality: Double = 0.82) { self.quality = quality }

    public func scaled(_ data: Data, maxWidth: Int) -> Data {
        guard maxWidth > 0,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        // 元幅 ≤ maxWidth なら縮小不要（拡大しない）。
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, w <= maxWidth {
            return data
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxWidth,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return data }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return data }
        CGImageDestinationAddImage(dest, thumb,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return data }
        return out as Data
    }
}
