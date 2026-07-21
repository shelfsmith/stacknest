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
        let urls = WatchFolderScanner.enumerateCandidates(folder: root, mode: .topLevelOnly)
        let names = Set(urls.map { $0.lastPathComponent })
        #expect(names.contains("top.zip"))
        #expect(!names.contains("inner.zip"))   // 直下のみ＝サブフォルダ内は拾わない
    }

    @Test func recurseIncludesSubfolderFileButNotDirectories() throws {
        let root = try makeTree(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = WatchFolderScanner.enumerateCandidates(folder: root, mode: .recurse)
        let names = Set(urls.map { $0.lastPathComponent })
        #expect(names.contains("top.zip"))
        #expect(names.contains("inner.zip"))    // 再帰でサブフォルダ内も拾う
        #expect(!names.contains("author_A"))    // ディレクトリ自体は候補にしない
    }

    // G9b: 3-way (ignore/archive/recurse) 列挙。監視フォルダに: top.cbz（素ファイル）, sub/（中に inner.cbz）を用意。
    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: root.appendingPathComponent("top.cbz"))
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: sub.appendingPathComponent("inner.cbz"))
        return root
    }

    @Test func ignoreEmitsOnlyTopLevelFiles_noSubfolder() throws {   // ← 漏れ修正の回帰テスト
        let root = try makeFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cands = WatchFolderScanner.enumerateCandidates(folder: root, mode: .topLevelOnly)
        let names = Set(cands.map { $0.lastPathComponent })
        #expect(names.contains("top.cbz"))
        #expect(!names.contains("sub"))        // サブフォルダは候補に出ない（従来はここが漏れていた）
        #expect(!names.contains("inner.cbz"))  // 中にも降りない
    }

    @Test func archiveEmitsSubdirsPlusTopLevelFiles() throws {
        let root = try makeFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cands = WatchFolderScanner.enumerateCandidates(folder: root, mode: .archive)
        let names = Set(cands.map { $0.lastPathComponent })
        #expect(names.contains("sub"))         // 直下サブフォルダ=1候補（=1冊）
        #expect(names.contains("top.cbz"))     // トップレベル素ファイルも候補
        #expect(!names.contains("inner.cbz"))  // 孫には降りない
    }

    @Test func recurseEmitsInnerFilesOnly() throws {
        let root = try makeFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cands = WatchFolderScanner.enumerateCandidates(folder: root, mode: .recurse)
        let names = Set(cands.map { $0.lastPathComponent })
        #expect(names.contains("top.cbz"))
        #expect(names.contains("inner.cbz"))   // 中のファイルを個別
        #expect(!names.contains("sub"))        // ディレクトリ自体は候補にしない
    }
}
