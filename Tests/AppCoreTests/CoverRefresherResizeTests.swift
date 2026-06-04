// SPDX-License-Identifier: MIT
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import AppCore

@Suite("CoverImageResizer")
struct CoverRefresherResizeTests {
    /// 指定サイズの単色 JPEG Data を生成する helper。
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

    @Test func downsamplesLargeInput() throws {
        let big = try makeJPEG(width: 2000, height: 3000)
        let resized = CoverImageResizer.resizeJPEG(big, maxPixelSize: 1200)
        let dims = dimensions(of: resized)
        #expect(dims != nil)
        #expect(dims!.0 <= 1200 && dims!.1 <= 1200)
        #expect(max(dims!.0, dims!.1) == 1200)
    }

    @Test func keepsSmallerInputIntact() throws {
        let small = try makeJPEG(width: 800, height: 1200)
        let resized = CoverImageResizer.resizeJPEG(small, maxPixelSize: 1200)
        let dims = dimensions(of: resized)
        #expect(dims != nil)
        #expect(max(dims!.0, dims!.1) <= 1200)
    }

    @Test func emptyInputReturnsEmpty() {
        let resized = CoverImageResizer.resizeJPEG(Data(), maxPixelSize: 1200)
        #expect(resized.isEmpty)
    }
}
