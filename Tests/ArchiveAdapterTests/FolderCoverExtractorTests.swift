// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

@Suite("FolderCoverExtractor")
struct FolderCoverExtractorTests {

    private func makeFolder(_ name: String, files: [(String, Data)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder_cover_\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (fname, data) in files {
            try data.write(to: dir.appendingPathComponent(fname))
        }
        return dir
    }

    @Test
    func extractsFirstImage() async throws {
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])  // PNG signature only
        let folder = try makeFolder("a", files: [
            ("readme.txt", Data("hi".utf8)),
            ("page01.png", pngData),
            ("page02.png", pngData)
        ])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let extractor = FolderCoverExtractor()
        let data = try await extractor.extractCoverImage(from: folder)
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test
    func extractsByLexicographicOrder() async throws {
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // Even though listed second, page01 should win lexicographically
        let folder = try makeFolder("b", files: [
            ("page99.png", Data([0x99])),
            ("page01.png", pngData)
        ])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let extractor = FolderCoverExtractor()
        let data = try await extractor.extractCoverImage(from: folder)
        #expect(data == pngData)
    }

    @Test
    func emptyFolderThrows() async throws {
        let folder = try makeFolder("empty", files: [])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let extractor = FolderCoverExtractor()
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await extractor.extractCoverImage(from: folder)
        }
    }

    @Test
    func skipsSubdirectories() async throws {
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let folder = try makeFolder("c", files: [
            ("readme.txt", Data("hi".utf8))
        ])
        // Add a subdirectory containing an image — should NOT be picked
        let sub = folder.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try pngData.write(to: sub.appendingPathComponent("page01.png"))
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let extractor = FolderCoverExtractor()
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await extractor.extractCoverImage(from: folder)
        }
    }

    @Test
    func countsImageEntries() async throws {
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let folder = try makeFolder("count_test", files: [
            ("readme.txt", Data("hi".utf8)),
            ("page01.png", pngData),
            ("page02.png", pngData),
            ("page03.jpg", pngData),
        ])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let extractor = FolderCoverExtractor()
        let count = try await extractor.countImageEntries(in: folder)
        #expect(count == 3)
    }

    @Test
    func countExcludesSubdirectoryImages() async throws {
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let folder = try makeFolder("count_subdir", files: [
            ("page01.png", pngData),
        ])
        // Subdirectory image should not be counted
        let sub = folder.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try pngData.write(to: sub.appendingPathComponent("page02.png"))
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let extractor = FolderCoverExtractor()
        let count = try await extractor.countImageEntries(in: folder)
        #expect(count == 1)
    }

    // MARK: - Phase 2.6b-2 T-C: heic/heif/tiff/tif/avif は画像として認識されること

    @Test
    func folderWithOnlyHeicYieldsAtLeastOneImageFile() async throws {
        // .heic ファイルのみを含むフォルダで countImageEntries >= 1 になることを確認する
        let heicData = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])  // ftyp box header (placeholder)
        let folder = try makeFolder("heic_only", files: [
            ("cover.heic", heicData),
            ("readme.txt", Data("hi".utf8))
        ])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let extractor = FolderCoverExtractor()
        let count = try await extractor.countImageEntries(in: folder)
        #expect(count >= 1, "フォルダに .heic ファイルが 1 枚あれば imageFiles >= 1 であること (T-C)")
    }

    @Test
    func folderWithHeifTiffAvifYieldsCorrectCount() async throws {
        let dummy = Data([0x00, 0x01, 0x02, 0x03])
        let folder = try makeFolder("multi_ext", files: [
            ("a.heif",  dummy),
            ("b.tiff",  dummy),
            ("c.tif",   dummy),
            ("d.avif",  dummy),
            ("e.txt",   Data("hi".utf8)),
        ])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let extractor = FolderCoverExtractor()
        let count = try await extractor.countImageEntries(in: folder)
        #expect(count == 4, "heif/tiff/tif/avif はすべて画像として認識されること (T-C)")
    }
}
