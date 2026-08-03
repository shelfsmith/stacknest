// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

@Suite("LibarchiveCoverExtractor")
struct LibarchiveCoverExtractorTests {

    private func fixture(_ name: String) -> URL {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()  // ArchiveAdapterTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    @Test
    func extractsFirstImageFromZip() async throws {
        let extractor = LibarchiveCoverExtractor()
        let data = try await extractor.extractCoverImage(from: fixture("sample_cover.zip"))
        #expect(data.count > 0)
        let sig = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(data.prefix(4) == sig)
    }

    @Test
    func extractsFirstImageFromCbz() async throws {
        let extractor = LibarchiveCoverExtractor()
        let data = try await extractor.extractCoverImage(from: fixture("sample_cover.cbz"))
        #expect(data.count > 0)
    }

    @Test
    func extractsFirstImageFromCbrIfAvailable() async throws {
        let url = fixture("sample_cover.cbr")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return  // rar(1) not installed at fixture build time
        }
        let extractor = LibarchiveCoverExtractor()
        let data = try await extractor.extractCoverImage(from: url)
        #expect(data.count > 0)
    }

    @Test
    func emptyZipReturnsNoImageEntry() async throws {
        let extractor = LibarchiveCoverExtractor()
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await extractor.extractCoverImage(from: fixture("empty.zip"))
        }
    }

    @Test
    func corruptZipReturnsArchiveUnreadable() async throws {
        let extractor = LibarchiveCoverExtractor()
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await extractor.extractCoverImage(from: fixture("corrupt.zip"))
        }
    }

    @Test
    func countsImagesInZip() async throws {
        let extractor = LibarchiveCoverExtractor()
        // sample_cover.zip contains page01.png and page02.png
        let result = try await extractor.countImageEntries(in: fixture("sample_cover.zip"))
        #expect(result.count == 2)
        #expect(result.truncated == false)
    }

    @Test
    func emptyZipCountsZero() async throws {
        let extractor = LibarchiveCoverExtractor()
        let result = try await extractor.countImageEntries(in: fixture("empty.zip"))
        #expect(result.count == 0)
        #expect(result.truncated == false)
    }

    // MARK: - Natural sort cover tests

    /// Creates a temporary zip whose entries are added in page03 → page01 → page02 order
    /// (simulating a ZIP where central-directory order ≠ filename sort order).
    /// The extractor must return page01's data, not page03's.
    @Test
    func extractsCoverByNaturalSortNotZipOrder() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sn-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Minimal distinct 1×1 PNG files: red, green, blue
        let red   = try Self.make1x1PNG(r: 255, g: 0,   b: 0)
        let green = try Self.make1x1PNG(r: 0,   g: 255, b: 0)
        let blue  = try Self.make1x1PNG(r: 0,   g: 0,   b: 255)

        // Write images in sorted filename order so we know which is "first"
        let p01 = tmpDir.appendingPathComponent("page01.png") // green → should be cover
        let p02 = tmpDir.appendingPathComponent("page02.png") // blue
        let p03 = tmpDir.appendingPathComponent("page03.png") // red
        try green.write(to: p01)
        try blue.write(to: p02)
        try red.write(to: p03)

        let zipURL = tmpDir.appendingPathComponent("test_sort.zip")
        // Add files to zip in page03 → page01 → page02 order (intentional mismatch)
        try Self.zipFiles([p03, p01, p02], to: zipURL, baseDir: tmpDir)

        let extractor = LibarchiveCoverExtractor()
        let coverData = try await extractor.extractCoverImage(from: zipURL)

        // page01 (green) must be the cover
        #expect(coverData == green, "Cover must be page01 (natural sort first), not the first-in-zip-order entry")
    }

    /// Verifies natural numeric ordering: page10 sorts after page2 (not before).
    @Test
    func handlesNaturalNumericOrder() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sn-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let img1  = try Self.make1x1PNG(r: 10, g: 20, b: 30) // page1  → cover
        let img2  = try Self.make1x1PNG(r: 40, g: 50, b: 60) // page2
        let img10 = try Self.make1x1PNG(r: 70, g: 80, b: 90) // page10

        let p1  = tmpDir.appendingPathComponent("page1.png")
        let p2  = tmpDir.appendingPathComponent("page2.png")
        let p10 = tmpDir.appendingPathComponent("page10.png")
        try img1.write(to: p1)
        try img2.write(to: p2)
        try img10.write(to: p10)

        let zipURL = tmpDir.appendingPathComponent("test_numeric.zip")
        // Add in page10 → page2 → page1 order (wrong order) to force extractor to sort
        try Self.zipFiles([p10, p2, p1], to: zipURL, baseDir: tmpDir)

        let extractor = LibarchiveCoverExtractor()
        let coverData = try await extractor.extractCoverImage(from: zipURL)

        #expect(coverData == img1, "Natural sort: page1 < page2 < page10, so cover is page1")
    }

    // MARK: - Helpers

    /// Creates a minimal valid 1×1 PNG with the given RGB colour.
    static func make1x1PNG(r: UInt8, g: UInt8, b: UInt8) throws -> Data {
        // PNG signature + IHDR + IDAT (single pixel, RGB, no alpha) + IEND
        var out = Data()

        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                var b = byte
                for _ in 0..<8 {
                    if (crc ^ UInt32(b)) & 1 == 1 {
                        crc = (crc >> 1) ^ 0xEDB8_8320
                    } else {
                        crc >>= 1
                    }
                    b >>= 1
                }
            }
            return crc ^ 0xFFFF_FFFF
        }

        func chunk(_ type: String, _ data: Data) -> Data {
            var c = Data()
            let typeBytes = type.utf8.prefix(4)
            let typeData  = Data(typeBytes)
            let len = UInt32(data.count)
            c.append(contentsOf: withUnsafeBytes(of: len.bigEndian, Array.init))
            c.append(typeData)
            c.append(data)
            let crcInput = typeData + data
            let checksum = crc32(crcInput)
            c.append(contentsOf: withUnsafeBytes(of: checksum.bigEndian, Array.init))
            return c
        }

        // PNG signature
        out.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // IHDR: 1×1 8-bit RGB
        var ihdr = Data()
        ihdr.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian, Array.init)) // width
        ihdr.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian, Array.init)) // height
        ihdr.append(contentsOf: [8, 2, 0, 0, 0]) // bitdepth=8 colorType=2(RGB) compress filter interlace
        out.append(chunk("IHDR", ihdr))

        // IDAT: zlib-compressed scanline (filter 0 + RGB)
        var raw = Data([0x00, r, g, b]) // filter None + pixel
        // zlib wrap (deflate stored block)
        var idat = Data()
        idat.append(contentsOf: [0x78, 0x01]) // zlib header
        // deflate non-compressed block: BFINAL=1, BTYPE=00
        idat.append(0x01) // final, stored
        let rawLen = UInt16(raw.count)
        idat.append(contentsOf: withUnsafeBytes(of: rawLen.littleEndian, Array.init))
        idat.append(contentsOf: withUnsafeBytes(of: (~rawLen).littleEndian, Array.init))
        idat.append(contentsOf: raw)
        // Adler-32 checksum
        var s1: UInt32 = 1, s2: UInt32 = 0
        for byte in raw { s1 = (s1 + UInt32(byte)) % 65521; s2 = (s2 + s1) % 65521 }
        let adler = (s2 << 16) | s1
        idat.append(contentsOf: withUnsafeBytes(of: adler.bigEndian, Array.init))
        out.append(chunk("IDAT", idat))

        // IEND
        out.append(chunk("IEND", Data()))
        return out
    }

    /// Zips the given files into destURL using /usr/bin/zip.
    /// Files are added in the order provided (determining zip central-directory order).
    static func zipFiles(_ files: [URL], to destURL: URL, baseDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -j: junk paths (store only filename, no directory prefix)
        process.arguments = ["-j", destURL.path] + files.map(\.path)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ZipHelper", code: Int(process.terminationStatus))
        }
    }
}
