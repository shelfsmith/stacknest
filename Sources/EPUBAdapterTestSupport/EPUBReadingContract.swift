// SPDX-License-Identifier: MIT
import Foundation
import Testing
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

        // 2. 表紙が JPEG か PNG で返る
        let cover = try await reader.coverImageData(url: withCover, maxPixelSize: 200)
        #expect(cover != nil)
        if let cover {
            let head = [UInt8](cover.prefix(4))
            let isJPEG = head.starts(with: [0xFF, 0xD8])
            let isPNG = head.starts(with: [0x89, 0x50, 0x4E, 0x47])
            #expect(isJPEG || isPNG, "JPEG でも PNG でもない: \(head)")
        }

        // 3. 表紙の無い本は nil（エラーではない）
        let noCover = try MinimalEPUB.make(in: dir, title: "表紙なし", author: nil, withCover: false)
        #expect(try await reader.coverImageData(url: noCover, maxPixelSize: 200) == nil)
        #expect(try await reader.open(url: noCover).author == nil)

        // 4. 壊れたファイルは cannotOpen
        let broken = dir.appendingPathComponent("broken.epub")
        try Data("not a zip".utf8).write(to: broken)
        await #expect(throws: EPUBAdapterError.self) { try await reader.open(url: broken) }
    }
}
