// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("LibraryBundle")
struct LibraryBundleTests {

    private func makeTempBundleURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).stacknest")
    }

    @Test("databaseURL appends library.sqlite")
    func databaseURL() {
        let bundle = LibraryBundle(url: URL(filePath: "/tmp/foo.stacknest"))
        #expect(bundle.databaseURL.lastPathComponent == "library.sqlite")
        #expect(bundle.databaseURL.path(percentEncoded: false) == "/tmp/foo.stacknest/library.sqlite")
    }

    @Test("thumbnailsDirectoryURL appends Thumbnails")
    func thumbnailsURL() {
        let bundle = LibraryBundle(url: URL(filePath: "/tmp/foo.stacknest"))
        #expect(bundle.thumbnailsDirectoryURL.lastPathComponent == "Thumbnails")
    }

    @Test("validate throws for non-existent URL")
    func validateMissingDirectory() {
        let bundle = LibraryBundle(url: URL(filePath: "/tmp/does-not-exist-\(UUID().uuidString).stacknest"))
        #expect(throws: LibraryBundleError.self) {
            try bundle.validate()
        }
    }

    @Test("validate throws when Info.plist is missing")
    func validateMissingInfoPlist() throws {
        let url = makeTempBundleURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        // Create an empty library.sqlite so we hit the Info.plist check
        try Data().write(to: url.appending(path: "library.sqlite"))
        let bundle = LibraryBundle(url: url)
        #expect(throws: LibraryBundleError.self) {
            try bundle.validate()
        }
    }

    @Test("validate throws when bundle version is unsupported")
    func validateUnsupportedVersion() throws {
        let url = makeTempBundleURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url.appending(path: "library.sqlite"))
        let plist: [String: Any] = [
            LibraryBundle.bundleVersionKey: 999,  // unsupported
            LibraryBundle.bundleIdentifierKey: LibraryBundle.bundleIdentifier
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appending(path: "Info.plist"))
        let bundle = LibraryBundle(url: url)
        #expect(throws: LibraryBundleError.unsupportedBundleVersion(999)) {
            try bundle.validate()
        }
    }
}
