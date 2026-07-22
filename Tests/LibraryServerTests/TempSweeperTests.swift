// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer

@Suite("TempSweeper")
struct TempSweeperTests {
    private func makeDir(_ parent: URL, _ name: String, ageHours: Double) throws -> URL {
        let d = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let when = Date().addingTimeInterval(-ageHours * 3600)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: d.path)
        return d
    }

    @Test func removesOnlyOldPrefixedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let old = try makeDir(root, "stacknest-arc-old", ageHours: 30)
        let fresh = try makeDir(root, "stacknest-arc-fresh", ageHours: 1)
        let other = try makeDir(root, "unrelated-dir", ageHours: 100)

        let now = Date()
        let removed = TempSweeper.sweep(in: root, prefix: "stacknest-arc-", olderThan: 24 * 3600, now: now)

        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))       // 24h 超 → 消える
        #expect(FileManager.default.fileExists(atPath: fresh.path))      // 稼働中の可能性 → 残す
        #expect(FileManager.default.fileExists(atPath: other.path))      // prefix 不一致 → 触らない
    }

    @Test func missingDirectoryIsNoOp() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(TempSweeper.sweep(in: missing, prefix: "stacknest-arc-", olderThan: 3600, now: Date()) == 0)
    }
}
