// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import EPUBAdapter
import WashiCore   // ← リポジトリでここだけ
import os

/// `WashiEPUBRenderer.swift` と同じ subsystem/category（同一モジュール内で file-private のため別インスタンス）。
private let epubReaderLog = Logger(subsystem: "app.shelfsmith.stacknest", category: "EPUBReader")

/// `shunnag/Washi`（1.16.0・revision c785293）による `EPUBReading` 実装。Washi の型を外に漏らさない。
public struct WashiEPUBReader: EPUBReading {
    public init() {}

    public func open(url: URL) async throws -> EPUBBookInfo {
        let pub = try await publication(url)
        return EPUBBookInfo(
            title: pub.metadata.mainTitle,
            author: pub.metadata.creators.first?.value,
            language: pub.metadata.languages.first,
            readingDirection: Self.resolvedDirection(of: pub))
    }

    public func coverImageData(url: URL, maxPixelSize: Int) async throws -> Data? {
        let pub = try await publication(url)
        guard let cg = pub.coverImage(maxPixelSize: maxPixelSize) else { return nil }
        return Self.jpegData(cg)
    }

    public func openImageBook(url: URL) async throws -> (any EPUBImageBookReading)? {
        let pub = try await publication(url)
        // 最終レビュー Important #1: 全 spine 項目を判定し切ってから判断するのではなく、最初にテキスト
        // ページが見つかった時点で打ち切る（数百項目のライトノベルを丸ごと展開・XML パースしない）。
        var paths: [String] = []
        var spreads: [EPUBPageSpread] = []
        for index in pub.readingOrder.indices {
            guard let info = try? pub.fixedLayoutInfo(forSpineIndex: index),
                  let path = info.simpleImagePath else {
                epubReaderLog.info("openImageBook: not an image book — spine index \(index, privacy: .public) is not a simple image page (containerPath=\(pub.readingOrder[index].containerPath, privacy: .private))")
                return nil
            }
            paths.append(path)
            spreads.append(Self.spread(from: info.pageSpread))
        }
        guard EPUBImageBookDetection.isImageBook(simpleImagePaths: paths.map { $0 as String? }) else { return nil }
        return WashiImageBook(publication: pub, imagePaths: paths, spreads: spreads)
    }

    private func publication(_ url: URL) async throws -> EPUBPublication {
        // NAS 上のファイルを mmap すると切断時に SIGBUS で落ちる。EPUB は数 MB
        // なのでコピーの代償は無視できる（Washi 自身が headless/server 文脈で推奨）。
        do { return try await EPUBPublication.open(url: url, readStrategy: .alwaysCopy) }
        catch { throw EPUBAdapterError.cannotOpen("\(type(of: error)): \(error)") }
    }

    /// Washi の enum 名に依存しないよう rawValue で写す（差し替え・更新で名前が変わっても壊れない）。
    static func direction(rawValue: String) -> ContractReadingDirection {
        switch rawValue.lowercased() {
        case "rtl": return .rtl
        case "ltr": return .ltr
        default: return .unknown
        }
    }

    /// G48-4: 宣言（page-progression-direction）があればそれ、`default`/未知なら Washi 1.16.0 の
    /// 実効値（primary-writing-mode → 冒頭 XHTML/CSS の縦書き → RTL 言語）で解決する。
    /// 両方 rawValue 文字列で受けるのは、上流の enum 名に依存しないため（`direction(rawValue:)` と同じ流儀）。
    static func direction(declared: String, effective: String) -> ContractReadingDirection {
        let d = direction(rawValue: declared)
        if d != .unknown { return d }
        return direction(rawValue: effective)
    }

    /// G48-4 最終レビュー C1: 上流の `effectiveReadingDirection` は手がかりが無いとき **表示用の既定 `ltr`** を
    /// 返す（`effectiveReadingDirectionSource == .fallback`）。それは「本の規定」ではないので採用せず
    /// `.unknown` に落とす（→ 取り込み時に書かない → ユーザーのグローバル既定＝右綴じに従う）。
    /// PPD 未宣言の漫画（本文 CSS が無く `ja` は RTL 言語でもない）は必ず `.fallback` になるため、これを
    /// 採用すると左綴じが行に焼き付く。`.fallback` はケース名で見る（壊れればコンパイルエラーになる依存）。
    static func resolvedDirection(of pub: EPUBPublication) -> ContractReadingDirection {
        let effective = pub.effectiveReadingDirectionSource == .fallback ? "" : pub.effectiveReadingDirection.rawValue
        return direction(declared: pub.readingDirection.rawValue, effective: effective)
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
