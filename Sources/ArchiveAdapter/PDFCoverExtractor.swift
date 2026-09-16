// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import PDFKit

/// G54-S4: PDF の各ページを表紙の候補として扱う抽出器。
///
/// アーカイブと違い実体のエントリ名が無いので、**ページ番号（1 始まり）を名前に使う**。
/// `preferredName` はページ番号として読む。読めない・範囲外なら 1 ページ目に落ちる
/// （契約が「見つからない名前で投げない」と定めているため）。
///
/// `ArchiveAdapter` は libarchive にしか依存していないが、PDFKit / AppKit は Apple の枠組みなので
/// パッケージの依存を増やさずに import できる（`page.thumbnail(of:for:)` が `NSImage` を返すため
/// `AppKit` の import が要る）。
///
/// **取り込み（`BookImporter`）では使わない。** `ArchiveAdapter.coverExtractor(for:)` のみが
/// `.pdf` でこれを返す。`importExtractor(for:)` は対象外のままにする — 取り込み時は
/// `PDFBookContent` が実際のページ数を書く専用経路を持つため。
public struct PDFCoverExtractor: CoverImageExtractor {
    /// 描く長辺の上限。既存の表紙が 1200px を基準にしているのに揃える。
    private static let maxPixelSize: CGFloat = 1200

    public init() {}

    public func listImageEntries(in url: URL) async throws -> ArchiveListing {
        let doc = try Self.open(url)
        guard doc.pageCount > 0 else { return ArchiveListing(names: [], truncated: false) }
        return ArchiveListing(names: (1...doc.pageCount).map(String.init), truncated: false)
    }

    public func countImageEntries(in url: URL) async throws -> ArchiveEntryCount {
        ArchiveEntryCount(count: try Self.open(url).pageCount, truncated: false)
    }

    public func extractCoverImage(from url: URL) async throws -> Data {
        try await extractCoverImage(from: url, preferredName: nil)
    }

    public func extractCoverImage(from url: URL, preferredName: String?) async throws -> Data {
        let doc = try Self.open(url)
        guard doc.pageCount > 0 else { throw PDFCoverExtractorError.noPages(url.path) }
        // 契約: 名前が無い・見つからないときは投げずに先頭へ落とす。
        let index = preferredName.flatMap(Int.init).map { $0 - 1 } ?? 0
        let page = doc.page(at: (0..<doc.pageCount).contains(index) ? index : 0)
        guard let page else { throw PDFCoverExtractorError.noPages(url.path) }
        return try Self.render(page)
    }

    private static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw PDFCoverExtractorError.unopenable(url.path) }
        return doc
    }

    private static func render(_ page: PDFPage) throws -> Data {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { throw PDFCoverExtractorError.emptyPage }
        let scale = min(1.0, maxPixelSize / max(bounds.width, bounds.height))
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw PDFCoverExtractorError.renderFailed
        }
        return png
    }
}

public enum PDFCoverExtractorError: Error, Sendable {
    case unopenable(String)
    case noPages(String)
    case emptyPage
    case renderFailed
}
