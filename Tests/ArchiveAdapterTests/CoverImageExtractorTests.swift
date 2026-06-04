// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

@Suite("CoverImageExtractor")
struct CoverImageExtractorTests {

    @Test("FolderCoverExtractor throws on non-existent path")
    func folderThrowsOnMissingPath() async {
        let extractor = FolderCoverExtractor()
        await #expect(throws: ArchiveAdapterError.self) {
            _ = try await extractor.extractCoverImage(from: URL(filePath: "/tmp/dummy_folder"))
        }
    }
}
