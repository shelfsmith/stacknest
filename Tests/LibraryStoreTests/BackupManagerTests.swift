// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("BackupManager")
struct BackupManagerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bmgr_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func changeCounterIncrementsAfterWrite() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: url, mode: .createOrReplace)
        try db.migrate()
        db.close()
        let before = BackupManager.changeCounter(of: url)
        #expect(before != nil)

        let db2 = try Database.openExisting(at: url)
        try db2.setLibrarySetting(key: "x", value: "1")
        db2.close()
        let after = BackupManager.changeCounter(of: url)
        #expect(after != nil)
        #expect(after != before)
    }

    @Test func changeCounterNilForMissingFile() throws {
        let dir = try tempDir()
        #expect(BackupManager.changeCounter(of: dir.appendingPathComponent("nope.sqlite")) == nil)
    }

    @Test func backupsDirIsBundleSubdir() {
        let bundle = URL(fileURLWithPath: "/tmp/foo.stacknest")
        #expect(BackupManager.backupsDir(for: bundle).lastPathComponent == "Backups")
        #expect(BackupManager.backupsDir(for: bundle).deletingLastPathComponent().path == bundle.path)
    }

    @Test func makeBackupCreatesDirAndFile() throws {
        let dir = try tempDir()
        let bundle = dir.appendingPathComponent("foo.stacknest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let db = try Database.openFile(at: bundle.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()

        let out = try BackupManager.makeBackup(from: db, bundleURL: bundle, timestamp: "20260607-101530")
        #expect(out.lastPathComponent == "library-20260607-101530.sqlite")
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(BackupManager.list(in: BackupManager.backupsDir(for: bundle)).count == 1)
    }

    /// 同一 timestamp（1 秒解像度）で 2 回バックアップしても上書きせず 2 世代残す（Codex Important #2 回帰）。
    @Test func makeBackupWithSameTimestampCreatesDistinctGenerations() throws {
        let dir = try tempDir()
        let bundle = dir.appendingPathComponent("foo.stacknest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let db = try Database.openFile(at: bundle.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()

        let a = try BackupManager.makeBackup(from: db, bundleURL: bundle, timestamp: "20260607-101530")
        let b = try BackupManager.makeBackup(from: db, bundleURL: bundle, timestamp: "20260607-101530")
        #expect(a.path != b.path)
        #expect(a.lastPathComponent == "library-20260607-101530.sqlite")
        #expect(b.lastPathComponent == "library-20260607-101530-2.sqlite")
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        #expect(BackupManager.list(in: BackupManager.backupsDir(for: bundle)).count == 2)
    }

    @Test func listIsNewestFirstAndPruneKeepsNewest() throws {
        let dir = try tempDir()
        let backupsDir = dir.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        // 名前順 = 時系列順。古い→新しい。
        for ts in ["20260601-000000", "20260602-000000", "20260603-000000", "20260604-000000"] {
            let f = backupsDir.appendingPathComponent("library-\(ts).sqlite")
            try Data("x".utf8).write(to: f)
        }
        let listed = BackupManager.list(in: backupsDir)
        #expect(listed.count == 4)
        #expect(listed.first!.lastPathComponent == "library-20260604-000000.sqlite") // newest first

        try BackupManager.prune(in: backupsDir, keep: 2)
        let after = BackupManager.list(in: backupsDir)
        #expect(after.count == 2)
        #expect(after.map { $0.lastPathComponent } == [
            "library-20260604-000000.sqlite",
            "library-20260603-000000.sqlite",
        ])
    }

    @Test func pruneIgnoresNonBackupFiles() throws {
        let dir = try tempDir()
        let backupsDir = dir.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: backupsDir.appendingPathComponent("library-20260601-000000.sqlite"))
        try Data("x".utf8).write(to: backupsDir.appendingPathComponent("README.txt"))
        try BackupManager.prune(in: backupsDir, keep: 0)
        #expect(FileManager.default.fileExists(atPath: backupsDir.appendingPathComponent("README.txt").path))
        #expect(BackupManager.list(in: backupsDir).isEmpty)
    }

    @Test func restoreLatestMovesCorruptAsideAndRestores() throws {
        let dir = try tempDir()
        let bundle = dir.appendingPathComponent("foo.stacknest")
        let backupsDir = BackupManager.backupsDir(for: bundle)
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        // live (corrupt) library + a sidecar journal
        let live = bundle.appendingPathComponent("library.sqlite")
        try Data("CORRUPT".utf8).write(to: live)
        try Data("J".utf8).write(to: bundle.appendingPathComponent("library.sqlite-journal"))
        // one backup
        try Data("GOODBACKUP".utf8).write(to: backupsDir.appendingPathComponent("library-20260605-000000.sqlite"))

        let restored = try BackupManager.restoreLatest(
            bundleURL: bundle, databaseFileName: "library.sqlite", timestamp: "20260607-120000")
        #expect(restored == true)
        // live now equals backup contents
        #expect(try String(contentsOf: live, encoding: .utf8) == "GOODBACKUP")
        // corrupt file preserved under a corrupt-<ts> name
        let corrupt = bundle.appendingPathComponent("library.corrupt-20260607-120000.sqlite")
        #expect(try String(contentsOf: corrupt, encoding: .utf8) == "CORRUPT")
        // stale sidecar removed
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("library.sqlite-journal").path))
    }

    @Test func restoreLatestReturnsFalseWhenNoBackups() throws {
        let dir = try tempDir()
        let bundle = dir.appendingPathComponent("foo.stacknest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("CORRUPT".utf8).write(to: bundle.appendingPathComponent("library.sqlite"))
        let restored = try BackupManager.restoreLatest(
            bundleURL: bundle, databaseFileName: "library.sqlite", timestamp: "20260607-120000")
        #expect(restored == false)
        // live untouched
        #expect(try String(contentsOf: bundle.appendingPathComponent("library.sqlite"), encoding: .utf8) == "CORRUPT")
    }
}
