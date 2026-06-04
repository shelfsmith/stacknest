// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

@Suite("ArchiveAdapter.coverExtractor(for:)")
struct ArchiveAdapterDispatchTests {

    @Test
    func zipReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.zip")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func cbzReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.cbz")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func cbrReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.cbr")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func folderReturnsFolderExtractor() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = ArchiveAdapter.coverExtractor(for: dir)
        #expect(ext is FolderCoverExtractor)
    }

    @Test
    func rarReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.rar")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func sevenZReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.7z")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func cb7ReturnsLibarchive() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.cb7")
        let ext = ArchiveAdapter.coverExtractor(for: url)
        #expect(ext is LibarchiveCoverExtractor)
    }

    @Test
    func unknownExtensionReturnsNil() throws {
        let url = URL(fileURLWithPath: "/tmp/foo.xyz")
        #expect(ArchiveAdapter.coverExtractor(for: url) == nil)
    }
}
