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

    @Test func noDownsampleNeededYieldsFullResolution() {
        // G19: native ≤ target（縮小不要）なら full-res 経路でネイティブ寸法をそのまま返す。
        let img = makeJPEG(width: 1521, height: 2160)   // 漫画ページ相当
        let decoded = ViewerImageDecoder.decode(img, maxPixelSize: 3000)  // target > native
        #expect(decoded != nil)
        guard let decoded else { return }
        #expect(decoded.cgImage.width == 1521)
        #expect(decoded.cgImage.height == 2160)
        #expect(decoded.pixelSize.width == 1521)
        #expect(decoded.pixelSize.height == 2160)
    }

    @Test func downsampleStillAppliesWhenNativeExceedsTarget() {
        // G19: native > target（縮小必要）は従来どおり thumbnail で target 以下に縮小する。
        let img = makeJPEG(width: 4000, height: 3000)
        let decoded = ViewerImageDecoder.decode(img, maxPixelSize: 2000)
        #expect(decoded != nil)
        guard let decoded else { return }
        let maxDim = max(decoded.cgImage.width, decoded.cgImage.height)
        #expect(maxDim <= 2010)
        #expect(maxDim >= 1990)
    }

    @Test func rotatedImageBakesOrientationEvenWhenNoDownsample() {
        // G19: 縮小不要でも回転ありは thumbnail-with-transform でベイク（寸法が入れ替わる）。
        let img = makeJPEG(width: 1521, height: 2160, orientation: 6)  // 90°回転
        let decoded = ViewerImageDecoder.decode(img, maxPixelSize: 3000)
        #expect(decoded != nil)
        guard let decoded else { return }
        #expect(decoded.cgImage.width == 2160)
        #expect(decoded.cgImage.height == 1521)
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

    // MARK: - G19 decodeLazy（AS 用フル解像度遅延デコード）

    /// 指定 EXIF orientation を埋め込んだ JPEG を合成する。
    private func makeJPEG(width: Int, height: Int, orientation: UInt32) -> Data {
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

    @Test func decodeLazyReturnsFullResolutionForUprightImage() {
        let data = makeJPEG(width: 2000, height: 1200)   // orientation 未指定＝up
        let decoded = ViewerImageDecoder.decodeLazy(data)
        #expect(decoded != nil)
        guard let decoded else { return }
        // フル解像度（縮小なし）で、pixelSize は CGImage 実寸と一致。
        #expect(decoded.cgImage.width == 2000)
        #expect(decoded.cgImage.height == 1200)
        #expect(decoded.pixelSize.width == 2000)
        #expect(decoded.pixelSize.height == 1200)
    }

    @Test func decodeLazyBakesOrientationForRotatedImage() {
        // orientation 6（90°回転）: ベイクされ、寸法が入れ替わる（2000x1200 → 1200x2000）。
        let data = makeJPEG(width: 2000, height: 1200, orientation: 6)
        let decoded = ViewerImageDecoder.decodeLazy(data)
        #expect(decoded != nil)
        guard let decoded else { return }
        #expect(decoded.cgImage.width == 1200)
        #expect(decoded.cgImage.height == 2000)
        #expect(decoded.pixelSize.width == CGFloat(decoded.cgImage.width))
        #expect(decoded.pixelSize.height == CGFloat(decoded.cgImage.height))
    }

    @Test func decodeLazyReturnsNilForUndecodable() {
        #expect(ViewerImageDecoder.decodeLazy(Data([0x00, 0x01, 0x02, 0x03])) == nil)
        #expect(ViewerImageDecoder.decodeLazy(Data()) == nil)
    }

    /// 指定形式で合成画像を書き出す（PNG の HW デコード非対応経路検証用）。
    private func makeImage(width: Int, height: Int, utType: UTType) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, utType.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func decodeLazyEagerlyDecodesNonHardwareFormats() {
        // G19 review Important #3: PNG（AS で HW デコード無し）は遅延にせず eager デコード＝
        // draw 時に main でソフトデコードが走らないよう即時展開される。full-res・寸法は保持。
        let png = makeImage(width: 1200, height: 1600, utType: .png)
        let decoded = ViewerImageDecoder.decodeLazy(png)
        #expect(decoded != nil)
        guard let decoded else { return }
        #expect(decoded.cgImage.width == 1200)
        #expect(decoded.cgImage.height == 1600)
        // eager（即時展開）: data provider がデコード済みバイトを持つ。
        #expect(decoded.cgImage.dataProvider?.data != nil)
    }

    @Test func decodeLazyCapsOversizedImages() {
        // G19 review Important #3: native が上限(6000px)を超える巨大画像は遅延せず縮小して返す。
        let huge = makeJPEG(width: 8000, height: 4000)
        let decoded = ViewerImageDecoder.decodeLazy(huge)
        #expect(decoded != nil)
        guard let decoded else { return }
        #expect(max(decoded.cgImage.width, decoded.cgImage.height) <= 6010)
    }
}
