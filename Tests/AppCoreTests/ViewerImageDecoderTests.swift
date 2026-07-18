// SPDX-License-Identifier: MIT
import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import AppCore

@Suite("ViewerImageDecoder")
struct ViewerImageDecoderTests {
    /// ImageTranscodingTests.makeJPEG と同一パターン（合成 JPEG を生成）。
    /// リポジトリの実 fixture（Tests/Fixtures 配下）はビューア用途で使うには小さすぎる
    /// プレースホルダ PNG（1x1 px 相当・69 bytes）のみのため、ここでは既存テストの
    /// 慣例に倣い、CGContext から十分大きな合成画像を生成してテストする。
    private func makeJPEG(width: Int, height: Int) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func downsamplesToMaxPixelSize() {
        let big = makeJPEG(width: 2000, height: 1200)
        let decoded = ViewerImageDecoder.decode(big, maxPixelSize: 256)
        #expect(decoded != nil)
        guard let decoded else { return }
        let maxDim = max(decoded.cgImage.width, decoded.cgImage.height)
        // ImageIO の thumbnail サイズ計算は端数処理で ±数px 揺れることがあるため小さな許容幅を持たせる。
        #expect(maxDim <= 260)
        #expect(maxDim >= 250)
        #expect(decoded.pixelSize.width == CGFloat(decoded.cgImage.width))
        #expect(decoded.pixelSize.height == CGFloat(decoded.cgImage.height))
    }

    @Test func zeroMaxPixelSizeYieldsNativeResolution() {
        let big = makeJPEG(width: 2000, height: 1200)
        let downsampled = ViewerImageDecoder.decode(big, maxPixelSize: 256)
        let native = ViewerImageDecoder.decode(big, maxPixelSize: 0)
        #expect(downsampled != nil)
        #expect(native != nil)
        guard let downsampled, let native else { return }
        let nativeMaxDim = max(native.cgImage.width, native.cgImage.height)
        let downsampledMaxDim = max(downsampled.cgImage.width, downsampled.cgImage.height)
        #expect(nativeMaxDim > downsampledMaxDim)
        // 元画像の長辺 (2000) に近い値であること。
        #expect(nativeMaxDim >= 1990)
        #expect(nativeMaxDim <= 2000)
    }

    @Test func negativeMaxPixelSizeAlsoYieldsNativeResolution() {
        let big = makeJPEG(width: 800, height: 500)
        let decoded = ViewerImageDecoder.decode(big, maxPixelSize: -1)
        #expect(decoded != nil)
        guard let decoded else { return }
        #expect(max(decoded.cgImage.width, decoded.cgImage.height) >= 790)
    }

    @Test func undecodableDataReturnsNil() {
        let junk = Data([0x00, 0x01, 0x02, 0x03])
        #expect(ViewerImageDecoder.decode(junk, maxPixelSize: 256) == nil)
    }

    @Test func emptyDataReturnsNil() {
        #expect(ViewerImageDecoder.decode(Data(), maxPixelSize: 256) == nil)
    }

    @Test func decodedImageIsEagerlyUsable() {
        let data = makeJPEG(width: 640, height: 480)
        let decoded = ViewerImageDecoder.decode(data, maxPixelSize: 320)
        #expect(decoded != nil)
        guard let decoded else { return }
        // 即時展開（eager decode）されていれば、data provider からピクセルバイト列を
        // 追加のデコード処理なしに取得できる。
        #expect(decoded.cgImage.dataProvider?.data != nil)
        #expect(decoded.cgImage.bitsPerPixel > 0)
    }

    // EXIF 回転タグ付き fixture がリポジトリに存在しないため、回転適用の直接検証は行わない
    // （kCGImageSourceCreateThumbnailWithTransform: true を ThumbnailLoader と同一に指定して
    // いることのみをコードでミラーする。実 EXIF fixture が追加され次第、別テストで補強する）。
}
