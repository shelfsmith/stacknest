// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

@Suite("LibarchiveImageData")
struct LibarchiveImageDataTests {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ArchiveAdapterTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    @Test func returnsDataForNamedEntry() async throws {
        let extractor = LibarchiveCoverExtractor()
        let names = try await extractor.listImageEntries(in: fixture("three_pages.zip"))
        #expect(names == ["p1.png", "p2.png", "p10.png"])
        let data = try await extractor.imageData(in: fixture("three_pages.zip"), entryName: "p2.png")
        #expect(data.count > 0)
        let pngSig = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(data.prefix(4) == pngSig)
    }

    @Test func throwsForMissingEntry() async throws {
        let extractor = LibarchiveCoverExtractor()
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await extractor.imageData(in: fixture("three_pages.zip"), entryName: "nonexistent.png")
        }
    }
}
