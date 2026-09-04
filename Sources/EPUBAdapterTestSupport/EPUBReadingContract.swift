// SPDX-License-Identifier: MIT
import Foundation
import Testing
import ImageIO
import EPUBAdapter

/// `EPUBReading` に適合する実装なら**必ず通るべき**試験。差し替え版の合格基準。
public enum EPUBReadingContract {
    public static func run(_ reader: any EPUBReading) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("epub-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. open → title / author / language / 綴じ方向
        let withCover = try MinimalEPUB.make(in: dir, title: "契約の本", author: "作者A", withCover: true)
        let info = try await reader.open(url: withCover)
        #expect(info.title == "契約の本")
        #expect(info.author == "作者A")
        #expect(info.language == "ja")
        #expect(info.readingDirection == .rtl)

        // 2. 表紙が JPEG か PNG で、CGImageSource でデコードでき、長辺が maxPixelSize 以下で返る
        let maxPixelSize = 200
        let cover = try await reader.coverImageData(url: withCover, maxPixelSize: maxPixelSize)
        #expect(cover != nil)
        if let cover {
            let head = [UInt8](cover.prefix(4))
            let isJPEG = head.starts(with: [0xFF, 0xD8])
            let isPNG = head.starts(with: [0x89, 0x50, 0x4E, 0x47])
            #expect(isJPEG || isPNG, "JPEG でも PNG でもない: \(head)")

            guard let source = CGImageSourceCreateWithData(cover as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int else {
                Issue.record("表紙画像を CGImageSourceCreateWithData でデコードできない")
                return
            }
            #expect(max(width, height) <= maxPixelSize, "長辺 \(max(width, height)) が maxPixelSize \(maxPixelSize) を超えている")
        }

        // 3. 表紙の無い本は nil（エラーではない）。title は必ず入る（本文が無くても OPF の必須要素）。
        let noCover = try MinimalEPUB.make(in: dir, title: "表紙なし", author: nil, withCover: false)
        #expect(try await reader.coverImageData(url: noCover, maxPixelSize: maxPixelSize) == nil)
        let noCoverInfo = try await reader.open(url: noCover)
        #expect(noCoverInfo.title != nil)
        #expect(noCoverInfo.author == nil)

        // 4. 壊れたファイルは open も coverImageData も cannotOpen
        let broken = dir.appendingPathComponent("broken.epub")
        try Data("not a zip".utf8).write(to: broken)
        await #expect(throws: EPUBAdapterError.self) { try await reader.open(url: broken) }
        await #expect(throws: EPUBAdapterError.self) { try await reader.coverImageData(url: broken, maxPixelSize: maxPixelSize) }
        // 最終レビュー Important #5: openImageBook も「開けなければ cannotOpen」を守ることを固定する。
        await #expect(throws: EPUBAdapterError.self) { _ = try await reader.openImageBook(url: broken) }

        // 5. 画像本: 全ページ画像なら handle が返り、ページ数・方向・画像が取れる
        let imageBook = try MinimalEPUB.makeImageBook(in: dir, pages: 3, direction: "rtl")
        let handle = try await reader.openImageBook(url: imageBook)
        #expect(handle != nil)
        if let handle {
            #expect(handle.pageCount == 3)
            #expect(handle.readingDirection == .rtl)
            #expect(handle.spreads.count == 3)
            for i in 0..<3 {
                let data = try await handle.imageData(at: i)
                let src = CGImageSourceCreateWithData(data as CFData, nil)
                #expect(src != nil && CGImageSourceGetCount(src!) == 1, "page \(i) は画像としてデコードできる")
            }
            await #expect(throws: (any Error).self) { _ = try await handle.imageData(at: 3) }
        }
        // 6. 混在本（テキストあり）は nil
        #expect(try await reader.openImageBook(url: withCover) == nil)
    }
}
