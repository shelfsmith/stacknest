// SPDX-License-Identifier: MIT
import AppKit
import Testing
import ImageIO
import UniformTypeIdentifiers
@testable import StackNest

/// G54-S3e（spec §2.6）: 切り取りの編集画面（`CoverCropPicker`）は `NSImage` の `size` から正規化座標を作る。
/// EXIF の向きの情報を持つ画像で `size` が回転前のままだと、切り取りが狙った範囲からずれる。
@MainActor
@Suite("G54-S3e: 切り取りの編集画面の画像の向き")
struct CoverPreviewOrientationTests {
    private func makeJPEG(width: Int, height: Int, orientation: UInt32) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func previewSizeFollowsTheEXIFOrientation() throws {
        let data = makeJPEG(width: 400, height: 200, orientation: 6)
        let image = try #require(NSImage(data: data))
        #expect(image.size == NSSize(width: 200, height: 400))
    }
}
