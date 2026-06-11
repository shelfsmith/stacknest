// SPDX-License-Identifier: MIT
import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import AppCore

@Suite("ImageTranscoding")
struct ImageTranscodingTests {
    @Test func passthroughReturnsIdenticalBytes() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let t = PassthroughTranscoder()
        #expect(t.scaled(data, maxWidth: 320) == data)
    }

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

    private func pixelWidth(of data: Data) -> Int? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int else { return nil }
        return w
    }

    @Test func imageIODownscalesToMaxWidth() {
        let big = makeJPEG(width: 1000, height: 600)
        let small = ImageIOTranscoder().scaled(big, maxWidth: 320)
        let w = pixelWidth(of: small)
        #expect(w.map { $0 <= 320 && $0 >= 318 } == true)
        #expect(small.count < big.count)
    }

    @Test func imageIOLeavesSmallerImagesUnchanged() {
        let small = makeJPEG(width: 200, height: 120)
        let out = ImageIOTranscoder().scaled(small, maxWidth: 320)
        #expect(out == small)
    }

    @Test func imageIOReturnsOriginalForNonImage() {
        let junk = Data([0x00, 0x01, 0x02, 0x03])
        #expect(ImageIOTranscoder().scaled(junk, maxWidth: 320) == junk)
    }
}
