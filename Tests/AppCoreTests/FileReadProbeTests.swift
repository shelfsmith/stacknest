// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G54-S3e: `AppState.ReadProbe` を AppCore へ移した。巻送りの事前確認（`VolumeHandover`）が使う。
@Suite("G54-S3e: ファイルが読めるか（FileReadProbe）")
struct FileReadProbeTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func readableFileAndFolder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.epub")
        try Data("x".utf8).write(to: file)
        #expect(FileReadProbe.check(file) == .readable)
        #expect(FileReadProbe.check(dir) == .readable)   // フォルダ型の本は「列挙できるか」
    }

    @Test func missingFileAndFolderAreNotFound() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileReadProbe.check(dir.appendingPathComponent("gone.epub")) == .notFound)
        #expect(FileReadProbe.check(dir.appendingPathComponent("gone-folder", isDirectory: true)) == .notFound)
    }

    @Test(.enabled(if: getuid() != 0, "root は権限で拒否されない"))
    func unreadableFileIsNoPermission() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("locked.zip")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(FileReadProbe.check(file) == .noPermission)
    }
}
