// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import EPUBAdapter
import WashiCore   // ← リポジトリでここだけ

/// `shunnag/Washi`（revision 8247b1d）による `EPUBReading` 実装。Washi の型を外に漏らさない。
public struct WashiEPUBReader: EPUBReading {
    public init() {}

    public func open(url: URL) async throws -> EPUBBookInfo {
        let pub = try await publication(url)
        return EPUBBookInfo(
            title: pub.metadata.mainTitle,
            author: pub.metadata.creators.first?.value,
            language: pub.metadata.languages.first,
            readingDirection: Self.direction(rawValue: pub.readingDirection.rawValue))
    }

    public func coverImageData(url: URL, maxPixelSize: Int) async throws -> Data? {
        let pub = try await publication(url)
        guard let cg = pub.coverImage(maxPixelSize: maxPixelSize) else { return nil }
        return Self.jpegData(cg)
    }

    public func openImageBook(url: URL) async throws -> (any EPUBImageBookReading)? {
        let pub = try await publication(url)
        let infos = pub.readingOrder.indices.map { try? pub.fixedLayoutInfo(forSpineIndex: $0) }
        let paths = infos.map { $0?.simpleImagePath }
        guard EPUBImageBookDetection.isImageBook(simpleImagePaths: paths) else { return nil }
        let spreads = infos.map { Self.spread(from: $0?.pageSpread) }
        return WashiImageBook(publication: pub, imagePaths: paths.compactMap { $0 }, spreads: spreads)
    }

    private func publication(_ url: URL) async throws -> EPUBPublication {
        // NAS 上のファイルを mmap すると切断時に SIGBUS で落ちる。EPUB は数 MB
        // なのでコピーの代償は無視できる（Washi 自身が headless/server 文脈で推奨）。
        do { return try await EPUBPublication.open(url: url, readStrategy: .alwaysCopy) }
        catch { throw EPUBAdapterError.cannotOpen("\(type(of: error)): \(error)") }
    }

    /// Washi の enum 名に依存しないよう rawValue で写す（差し替え・更新で名前が変わっても壊れない）。
    static func direction(rawValue: String) -> EPUBReadingDirection {
        switch rawValue.lowercased() {
        case "rtl": return .rtl
        case "ltr": return .ltr
        default: return .unknown
        }
    }

    /// Washi の `PageSpreadSlot` を rawValue 文字列で写す（enum 名に依存しない）。nil は "none" 扱い。
    static func spread(from slot: PageSpreadSlot?) -> EPUBPageSpread {
        switch slot?.rawValue.lowercased() {
        case "left": return .left
        case "right": return .right
        case "center": return .center
        default: return .none
        }
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
