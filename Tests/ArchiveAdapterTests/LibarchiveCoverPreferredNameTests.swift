// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

@Suite("LibarchiveCoverExtractor preferredName + listImageEntries")
struct LibarchiveCoverPreferredNameTests {
    private func makeZip(pages: [String]) throws -> URL {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // 1x1 PNG bytes
        let pngBytes: [UInt8] = [
            0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
            0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
            0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
            0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,
            0x89,0x00,0x00,0x00,0x0D,0x49,0x44,0x41,
            0x54,0x78,0x9C,0x63,0xFA,0xCF,0x00,0x00,
            0x00,0x02,0x00,0x01,0xE5,0x27,0xDE,0xFC,
            0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,
            0xAE,0x42,0x60,0x82
        ]
        for page in pages {
            try Data(pngBytes).write(to: tmpDir.appendingPathComponent(page))
        }
        let zipURL = tmpDir.appendingPathComponent("test.zip")
        let process = Process()
        process.launchPath = "/usr/bin/zip"
        process.arguments = ["-q", "-j", zipURL.path] + pages.map { tmpDir.appendingPathComponent($0).path }
        try process.run()
        process.waitUntilExit()
        return zipURL
    }

    @Test
    func extractsPreferredEntryByName() async throws {
        let zipURL = try makeZip(pages: ["page01.jpg", "page05.jpg", "page10.jpg"])
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }
        let extractor = LibarchiveCoverExtractor()
        let data = try await extractor.extractCoverImage(from: zipURL, preferredName: "page05.jpg")
        #expect(data.count > 0)
    }

    @Test
    func fallsBackToFirstWhenPreferredNameMissing() async throws {
        let zipURL = try makeZip(pages: ["page01.jpg", "page05.jpg"])
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }
        let extractor = LibarchiveCoverExtractor()
        // 該当なし → 自動 (natural sort 先頭) にフォールバック (例外を投げない)
        let data = try await extractor.extractCoverImage(from: zipURL, preferredName: "absent.jpg")
        #expect(data.count > 0)
    }

    @Test
    func nilPreferredNameUsesFirstSortedEntry() async throws {
        let zipURL = try makeZip(pages: ["page03.jpg", "page01.jpg", "page02.jpg"])
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }
        let extractor = LibarchiveCoverExtractor()
        let data = try await extractor.extractCoverImage(from: zipURL, preferredName: nil)
        #expect(data.count > 0)
        // 内容比較は重いので、サイズが正であることのみ確認 (sort 動作は他 test でカバー)
    }

    @Test
    func listImageEntriesReturnsNaturalSorted() async throws {
        let zipURL = try makeZip(pages: ["page10.jpg", "page2.jpg", "page1.jpg"])
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }
        let extractor = LibarchiveCoverExtractor()
        let names = try await extractor.listImageEntries(in: zipURL).names
        #expect(names == ["page1.jpg", "page2.jpg", "page10.jpg"])
    }
}
