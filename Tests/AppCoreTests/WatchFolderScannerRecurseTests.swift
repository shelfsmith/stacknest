// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("WatchFolderScanner.enumerateCandidates recurse")
struct WatchFolderScannerRecurseTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wfs-\(UUID().uuidString)", isDirectory: true)
        let sub = root.appendingPathComponent("author_A", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("top.zip"))
        try Data("b".utf8).write(to: sub.appendingPathComponent("inner.zip"))
        return root
    }

    @Test func topLevelDoesNotIncludeSubfolderFile() throws {
        let root = try makeTree(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = WatchFolderScanner.enumerateCandidates(folder: root, recurse: false)
        let names = Set(urls.map { $0.lastPathComponent })
        #expect(names.contains("top.zip"))
        #expect(!names.contains("inner.zip"))   // 直下のみ＝サブフォルダ内は拾わない
    }

    @Test func recurseIncludesSubfolderFileButNotDirectories() throws {
        let root = try makeTree(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = WatchFolderScanner.enumerateCandidates(folder: root, recurse: true)
        let names = Set(urls.map { $0.lastPathComponent })
        #expect(names.contains("top.zip"))
        #expect(names.contains("inner.zip"))    // 再帰でサブフォルダ内も拾う
        #expect(!names.contains("author_A"))    // ディレクトリ自体は候補にしない
    }
}
