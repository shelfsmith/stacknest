// SPDX-License-Identifier: MIT
import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// B20 + B21 (Phase 2.5i): PDF 1 ページ目を表紙画像化 + ページ数取得。
/// 単独 .pdf URL を渡すか、アーカイブ内 PDF を一時ファイルに展開してから渡す (caller 責務)。
///
/// Phase 4.0: 描画を `NSImage.lockFocus` から `CGBitmapContext` + ImageIO に置換し
/// AppKit 依存を除去。これによりレンダリングは main thread 非依存になった。
/// ただし `PDFDocument` は Sendable ではなく並行アクセス安全でもないため、
/// **同一インスタンスへのアクセスは直列化が必要**（BookContent 経路は現状
/// `PDFPageContent` が `MainActor.run` で直列化している。Phase 4.0 後続タスクで
/// actor 化し、main 非依存の直列化に移行予定。同期利用の C5 BookAddCoordinator /
/// CoverRegenerationTask は従来どおり MainActor 上の局所利用）。
public struct PDFBookContent {
    public let url: URL
    private let document: PDFDocument

    public init?(url: URL) {
        guard let doc = PDFDocument(url: url) else { return nil }
        self.url = url
        self.document = doc
    }

    public var pageCount: Int { document.pageCount }

    /// 1 ページ目を JPEG Data 化。`maxPixelSize` は出力画像の長辺上限 (B19 規約に合わせて default 1200)。
    /// 1 ページ目が取得できなければ nil。
    public func coverJPEG(maxPixelSize: Int = 1200) -> Data? {
        pageImageData(at: 0, maxPixelSize: maxPixelSize)
    }

    /// 指定ページ (0-based) を JPEG Data 化。範囲外・描画失敗時は nil。
    /// 内蔵ビューワ (Phase 2.6b) のページ取得・Phase 4.1a サーバ配信で使用。
    /// 白背景・長辺 maxPixelSize・JPEG 品質 0.85（旧 lockFocus 実装と同一仕様）。
    public func pageImageData(at index: Int, maxPixelSize: Int = 1200) -> Data? {
        precondition(maxPixelSize >= 1, "maxPixelSize must be >= 1")
        guard index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(maxPixelSize) / max(bounds.width, bounds.height)
        let pixelWidth = max(1, Int((bounds.width * scale).rounded()))
        let pixelHeight = max(1, Int((bounds.height * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.saveGState()
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        guard let cgImage = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
