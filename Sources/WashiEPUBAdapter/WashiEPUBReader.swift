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

    private func publication(_ url: URL) async throws -> EPUBPublication {
        do { return try await EPUBPublication.open(url: url) }
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

    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
