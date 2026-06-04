// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite struct BookCategoryTests {
    @Test func classifiesArchiveExtensions() {
        #expect(BookCategory.classify(path: "/tmp/foo.zip") == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.cbz") == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.rar") == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.cbr") == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.7z") == .archive)
    }

    @Test func classifiesImageExtensions() {
        #expect(BookCategory.classify(path: "/tmp/foo.jpg") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.jpeg") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.png") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.gif") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.webp") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.heic") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.heif") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.bmp") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.tiff") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.tif") == .image)
    }

    @Test func classifiesVideoExtensions() {
        #expect(BookCategory.classify(path: "/tmp/foo.mp4") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.mov") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.avi") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.mkv") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.webm") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.m4v") == .video)
    }

    @Test func classifiesTextExtensions() {
        #expect(BookCategory.classify(path: "/tmp/foo.pdf") == .text)
        #expect(BookCategory.classify(path: "/tmp/foo.epub") == .text)
        #expect(BookCategory.classify(path: "/tmp/foo.txt") == .text)
        #expect(BookCategory.classify(path: "/tmp/foo.md") == .text)
        #expect(BookCategory.classify(path: "/tmp/foo.rtf") == .text)
    }

    @Test func classifiesUppercaseExtensions() {
        #expect(BookCategory.classify(path: "/tmp/foo.JPG") == .image)
        #expect(BookCategory.classify(path: "/tmp/foo.MP4") == .video)
        #expect(BookCategory.classify(path: "/tmp/foo.ZIP") == .archive)
        #expect(BookCategory.classify(path: "/tmp/foo.PDF") == .text)
    }

    @Test func classifiesUnknownExtensionAsArchiveFallback() {
        #expect(BookCategory.classify(path: "/tmp/foo.xyz") == .archive)
        #expect(BookCategory.classify(path: "/tmp/noext") == .archive)
    }

    @Test func classifiesExistingDirectoryAsFolder() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "BookCategoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        #expect(BookCategory.classify(path: tempDir.path(percentEncoded: false)) == .folder)
    }

    @Test func displayNameAndHintAreNonEmpty() {
        for category in BookCategory.allCases {
            #expect(!category.displayName.isEmpty)
            #expect(!category.extensionsHint.isEmpty)
        }
    }
}
