// SPDX-License-Identifier: MIT
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 画像バイト列の縮小・再圧縮の抽象（4.1c）。
/// LibraryServer はこの protocol 経由で注入を受ける（ImageIO 直接 import を避ける）。
public protocol ImageTranscoding: Sendable {
    /// 実際に縮小を行う実装なら true（capability /server/info の transcode 申告に使う）。
    var supportsScaling: Bool { get }
    /// 画像を最大幅 `maxWidth` px に縮小して返す。
    /// 縮小不要（元幅 ≤ maxWidth）・非画像・失敗時は元データをそのまま返す（決して throw しない）。
    func scaled(_ data: Data, maxWidth: Int) -> Data
}

/// 縮小しない既定実装（Docker v1・テスト用）。
public struct PassthroughTranscoder: ImageTranscoding {
    public init() {}
    public var supportsScaling: Bool { false }
    public func scaled(_ data: Data, maxWidth: Int) -> Data { data }
}

/// ImageIO による縮小・JPEG 再圧縮（Mac 実装）。
public struct ImageIOTranscoder: ImageTranscoding {
    public var quality: Double
    public init(quality: Double = 0.82) { self.quality = quality }
    public var supportsScaling: Bool { true }

    public func scaled(_ data: Data, maxWidth: Int) -> Data {
        guard maxWidth > 0,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        // G54-S3e（spec §2.6）: 回転の印（EXIF orientation）が 1 以外なら元のバイト列を返さない。
        // 受け手（NSImage・Web・他の縮小経路）ごとに印の扱いが揃っている保証が無いので、再エンコードで回転を焼き込む。
        let orientation = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
        var maxPixelSize = maxWidth
        // G54-S3e 最終レビュー: orientation 5–8 は 90°回転を伴うので、表示上の幅は元の「高さ」
        // （`kCGImageSourceCreateThumbnailWithTransform: true` が回転を適用した後の幅）。
        // 元の幅のまま比較すると、縦長の元画像が 90°回転で横長になるケースの縮小要否を取り違える。
        if let w = props?[kCGImagePropertyPixelWidth] as? Int,
           let h = props?[kCGImagePropertyPixelHeight] as? Int {
            let displayedWidth = (5...8).contains(orientation) ? h : w
            // 表示上の幅 ≤ maxWidth なら縮小不要（拡大しない）。
            if displayedWidth <= maxWidth {
                guard orientation != 1 else { return data }
                maxPixelSize = max(w, h)   // 縮めずに、回転だけ焼き込む
            }
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
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
