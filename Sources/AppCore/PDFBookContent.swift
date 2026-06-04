// SPDX-License-Identifier: MIT
import Foundation
import PDFKit
import AppKit

/// B20 + B21 (Phase 2.5i): PDF 1 ページ目を表紙画像化 + ページ数取得。
/// 単独 .pdf URL を渡すか、アーカイブ内 PDF を一時ファイルに展開してから渡す (caller 責務)。
///
/// Note: `PDFDocument` は Sendable ではないため Sendable 適合は付けない。
/// 利用側 (C5 BookAddCoordinator) は MainActor 上で扱う前提。
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
    /// 内蔵ビューワ (Phase 2.6b) のページ取得で使用。
    public func pageImageData(at index: Int, maxPixelSize: Int = 1200) -> Data? {
        precondition(maxPixelSize >= 1, "maxPixelSize must be >= 1")
        guard index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(maxPixelSize) / max(bounds.width, bounds.height)
        let pixelSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        let image = NSImage(size: pixelSize)
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: pixelSize))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
