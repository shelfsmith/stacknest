// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// G54-S3e: EXIF の向きの情報（Orientation）を埋め込んだ JPEG を合成し、読み取る（AppCoreTests で共有）。
enum OrientedJPEGFixture {
    /// `width`×`height` の画素を持ち、指定の EXIF の向きの情報を付けた JPEG。
    static func make(width: Int, height: Int, orientation: UInt32) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// 画素の幅・高さと EXIF の向きの情報（無ければ 1）。
    static func info(_ data: Data) -> (width: Int, height: Int, orientation: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int,
              let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h, (p[kCGImagePropertyOrientation] as? Int) ?? 1)
    }

    /// EXIF の向きの情報を当てた後の見た目の幅と高さ（値 5〜8 は縦横が入れ替わる）。
    static func displayedSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let i = info(data) else { return nil }
        return (5...8).contains(i.orientation) ? (i.height, i.width) : (i.width, i.height)
    }
}
