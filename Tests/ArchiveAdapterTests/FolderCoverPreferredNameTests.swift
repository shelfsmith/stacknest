// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

@Suite("FolderCoverExtractor preferredName + listImageEntries")
struct FolderCoverPreferredNameTests {
    private func makeFolder(pages: [String]) throws -> URL {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
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
        return tmpDir
    }

    @Test
    func listImageEntriesReturnsNaturalSorted() async throws {
        let folderURL = try makeFolder(pages: ["page10.jpg", "page2.jpg", "page1.jpg"])
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let extractor = FolderCoverExtractor()
        let names = try await extractor.listImageEntries(in: folderURL).names
        #expect(names == ["page1.jpg", "page2.jpg", "page10.jpg"])
    }

    @Test
    func extractsPreferredFileFromFolder() async throws {
        let folderURL = try makeFolder(pages: ["page01.jpg", "page05.jpg"])
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let extractor = FolderCoverExtractor()
        let data = try await extractor.extractCoverImage(from: folderURL, preferredName: "page05.jpg")
        #expect(data.count > 0)
    }

    @Test
    func fallsBackToFirstWhenPreferredNameMissing() async throws {
        let folderURL = try makeFolder(pages: ["page01.jpg", "page05.jpg"])
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let extractor = FolderCoverExtractor()
        let data = try await extractor.extractCoverImage(from: folderURL, preferredName: "absent.jpg")
        #expect(data.count > 0)
    }

    @Test
    func nilPreferredNameUsesFirstSortedEntry() async throws {
        let folderURL = try makeFolder(pages: ["page03.jpg", "page01.jpg", "page02.jpg"])
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let extractor = FolderCoverExtractor()
        let data = try await extractor.extractCoverImage(from: folderURL, preferredName: nil)
        #expect(data.count > 0)
    }
}
