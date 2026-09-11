// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import LibraryServerAPI

/// G51 smoke 9.3: `offlineFileExtension(for:fileAt:)` がサーバの `fileExtension` を優先し、
/// 無い／不正なときだけ magic 推定にフォールバックすることを確認する。テストデータは架空の値のみ。
@Suite("offlineFileExtension(for:fileAt:) — server extension over magic guess")
struct OfflineFileExtensionTests {
    private func detail(fileExtension: String?) -> BookDetailDTO {
        BookDetailDTO(id: 1, title: "T", author: nil, genre: nil, path: nil,
            dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 2, pages: nil,
            rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil,
            series: nil, volume: nil, coverImageName: nil, coverCropRectJSON: nil, pageDirection: nil,
            fileExtension: fileExtension)
    }

    private func withTempFile(bytes: [UInt8], _ body: (URL) throws -> Void) rethrows {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-ext-test-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    @Test func serverExtensionWinsOverMagicGuess() {
        // PK... の magic はふつう "zip" と推定されるが、サーバが "epub" を返していればそちらを使う。
        withTempFile(bytes: [0x50, 0x4B, 0x03, 0x04]) { url in
            let d = detail(fileExtension: "epub")
            #expect(offlineFileExtension(for: d, fileAt: url) == "epub")
        }
    }

    @Test func nilServerExtensionFallsBackToMagicGuessZip() {
        withTempFile(bytes: [0x50, 0x4B, 0x03, 0x04]) { url in
            let d = detail(fileExtension: nil)
            #expect(offlineFileExtension(for: d, fileAt: url) == "zip")
        }
    }

    @Test func nilServerExtensionFallsBackToMagicGuessPDF() {
        withTempFile(bytes: [0x25, 0x50, 0x44, 0x46]) { url in
            let d = detail(fileExtension: nil)
            #expect(offlineFileExtension(for: d, fileAt: url) == "pdf")
        }
    }

    @Test func invalidServerExtensionFallsBackToMagicGuess() {
        withTempFile(bytes: [0x50, 0x4B, 0x03, 0x04]) { url in
            #expect(offlineFileExtension(for: detail(fileExtension: "../etc"), fileAt: url) == "zip")
            #expect(offlineFileExtension(for: detail(fileExtension: ""), fileAt: url) == "zip")
            #expect(offlineFileExtension(for: detail(fileExtension: "toolongextension"), fileAt: url) == "zip")
        }
    }

    @Test func serverExtensionIsLowercased() {
        withTempFile(bytes: [0x50, 0x4B, 0x03, 0x04]) { url in
            let d = detail(fileExtension: "EPUB")
            #expect(offlineFileExtension(for: d, fileAt: url) == "epub")
        }
    }
}
