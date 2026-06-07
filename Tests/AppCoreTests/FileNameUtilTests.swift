// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("FileNameUtil.withoutExtension")
struct FileNameUtilTests {
    @Test func stripsExtensionFromFile() {
        #expect(FileNameUtil.withoutExtension(path: "/a/b/book01.zip") == "book01")
    }
    @Test func keepsAllButLastDotSegment() {
        #expect(FileNameUtil.withoutExtension(path: "/a/b/vol.1.zip") == "vol.1")
    }
    @Test func folderWithoutExtensionStays() {
        #expect(FileNameUtil.withoutExtension(path: "/a/b/MySet") == "MySet")
    }
    @Test func trailingSlashFolderNormalized() {
        #expect(FileNameUtil.withoutExtension(path: "/a/b/MySet/") == "MySet")
    }
}
