// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("DatabaseRecovery (.recover)")
struct DatabaseRecoveryTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recover_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func recoverRebuildsOpenableDBFromCorruptSource() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("library.sqlite")
        let db = try Database.openFile(at: src, mode: .createOrReplace)
        try db.migrate()
        for i in 0..<300 {
            try db.setLibrarySetting(key: "k\(i)", value: String(repeating: "v", count: 64))
        }
        db.close()
        // ヘッダ(先頭100B)は保ったまま、後方ページ(5ページ目先頭)の btree を破壊。
        let handle = try FileHandle(forUpdating: src)
        try handle.seek(toOffset: 4096 * 4)
        try handle.write(contentsOf: Data(repeating: 0, count: 512))
        try handle.close()

        let out = dir.appendingPathComponent("recovered.sqlite")
        let ok = try DatabaseRecovery.recover(from: src, to: out)
        #expect(ok == true)

        // 救出結果は openable かつ quick_check 正常、book テーブルのスキーマを保持。
        let r = try Database.openExisting(at: out)
        #expect(try r.quickCheck() == true)
        #expect(try r.fetchBookColumnNames().contains("title"))

        // .recover の本来の目的＝データ行の救出を検証する（best-effort なので全件ではなく一定数）。
        var survivors = 0
        for i in 0..<300 {
            if let v = try? r.getLibrarySetting(key: "k\(i)"), v != nil { survivors += 1 }
        }
        #expect(survivors > 50)
    }

    @Test func recoverReturnsFalseWhenSourceMissing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.sqlite")
        #expect(try DatabaseRecovery.recover(
            from: dir.appendingPathComponent("nope.sqlite"), to: out) == false)
    }
}
