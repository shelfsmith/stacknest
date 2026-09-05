// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("G48-3: リモート EPUB のキャッシュ")
struct RemoteEPUBCacheTests {
    private func tmpDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("remote-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    @Test func pathShape() throws {
        let c = RemoteEPUBCache(baseDirectory: try tmpDir())
        let sid = UUID()
        let u = c.fileURL(serverID: sid, libraryUUID: "LIB", bookID: 7)
        #expect(u.path.hasSuffix("/\(sid.uuidString)/LIB/7.epub"))
    }
    @Test func storeMovesAndReuses() throws {
        let c = RemoteEPUBCache(baseDirectory: try tmpDir())
        let sid = UUID()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try Data("epub".utf8).write(to: tmp)
        let stored = try c.store(temporaryFile: tmp, serverID: sid, libraryUUID: "LIB", bookID: 1)
        #expect(FileManager.default.fileExists(atPath: stored.path))
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
        #expect(c.fileURL(serverID: sid, libraryUUID: "LIB", bookID: 1) == stored)
    }
    @Test func pruneKeepsNewest() throws {
        let c = RemoteEPUBCache(baseDirectory: try tmpDir())
        let sid = UUID()
        for i in 0..<5 {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try Data("x".utf8).write(to: tmp)
            let u = try c.store(temporaryFile: tmp, serverID: sid, libraryUUID: "LIB", bookID: i)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + i))], ofItemAtPath: u.path)
        }
        c.prune(keep: 2)
        let left = (0..<5).filter { FileManager.default.fileExists(atPath: c.fileURL(serverID: sid, libraryUUID: "LIB", bookID: $0).path) }
        #expect(left == [3, 4])
    }
}
