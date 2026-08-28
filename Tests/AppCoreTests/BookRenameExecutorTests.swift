// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("改名の実行")
struct BookRenameExecutorTests {
    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g47-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL, _ text: String = "x") throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("ok の行だけを改名し、パス更新を呼ぶ")
    func appliesOnlyOK() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.zip")
        let b = dir.appendingPathComponent("b.zip")
        try touch(a); try touch(b)

        let rows = [
            RenamePlanRow(id: 1, oldPath: a.path, newPath: dir.appendingPathComponent("A新.zip").path,
                          oldName: "a.zip", newName: "A新.zip", status: .ok),
            RenamePlanRow(id: 2, oldPath: b.path, newPath: dir.appendingPathComponent("B新.zip").path,
                          oldName: "b.zip", newName: "B新.zip", status: .conflictExisting),
        ]
        var updated: [(Int, String)] = []
        let result = BookRenameExecutor.apply(rows: rows) { id, path in updated.append((id, path)) }

        #expect(result.applied == 1)
        #expect(result.failed.isEmpty)
        #expect(updated.count == 1)
        #expect(updated[0].0 == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("A新.zip").path))
        #expect(FileManager.default.fileExists(atPath: b.path))   // 触っていない
    }

    @Test("★ 大文字小文字だけの改名が通る")
    func caseOnlyRename() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("abc.zip")
        try touch(a, "content")

        let row = RenamePlanRow(id: 1, oldPath: a.path,
                                newPath: dir.appendingPathComponent("ABC.zip").path,
                                oldName: "abc.zip", newName: "ABC.zip", status: .ok)
        var updated: [(Int, String)] = []
        let result = BookRenameExecutor.apply(rows: [row]) { id, path in updated.append((id, path)) }

        #expect(result.applied == 1)
        #expect(updated.count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["ABC.zip"])
        let text = try String(contentsOf: dir.appendingPathComponent("ABC.zip"), encoding: .utf8)
        #expect(text == "content")   // 一時名を経由しても中身は失われない
    }

    @Test("1 件失敗しても残りは続ける")
    func continuesAfterFailure() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.zip")
        try touch(good)

        let rows = [
            RenamePlanRow(id: 1, oldPath: dir.appendingPathComponent("居ない.zip").path,
                          newPath: dir.appendingPathComponent("x.zip").path,
                          oldName: "居ない.zip", newName: "x.zip", status: .ok),
            RenamePlanRow(id: 2, oldPath: good.path,
                          newPath: dir.appendingPathComponent("良.zip").path,
                          oldName: "good.zip", newName: "良.zip", status: .ok),
        ]
        let result = BookRenameExecutor.apply(rows: rows) { _, _ in }
        #expect(result.applied == 1)
        #expect(result.failed.count == 1)
        #expect(result.failed[0].id == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("良.zip").path))
    }

    @Test("パス更新が投げても実行結果は失敗として残る")
    func updateThrows() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.zip")
        try touch(a)
        struct E: Error {}
        let row = RenamePlanRow(id: 1, oldPath: a.path,
                                newPath: dir.appendingPathComponent("新.zip").path,
                                oldName: "a.zip", newName: "新.zip", status: .ok)
        let result = BookRenameExecutor.apply(rows: [row]) { _, _ in throw E() }
        #expect(result.applied == 0)
        #expect(result.failed.count == 1)
    }

    @Test("updatePath が投げたらファイルは元の名前に戻る")
    func updateThrowsRollsBackFile() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.zip")
        let newPath = dir.appendingPathComponent("新.zip")
        try touch(a, "content")
        struct E: Error {}
        let row = RenamePlanRow(id: 1, oldPath: a.path, newPath: newPath.path,
                                oldName: "a.zip", newName: "新.zip", status: .ok)
        let result = BookRenameExecutor.apply(rows: [row]) { _, _ in throw E() }

        #expect(result.applied == 0)
        #expect(result.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: newPath.path))
    }

    @Test("大文字小文字だけの改名の 2 歩目が落ちたら元に戻る")
    func caseOnlyRenameStagingFails() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("abc.zip")
        try touch(a, "content")

        let row = RenamePlanRow(id: 1, oldPath: a.path,
                                newPath: dir.appendingPathComponent("ABC.zip").path,
                                oldName: "abc.zip", newName: "ABC.zip", status: .ok)
        let fm = FailingFileManager(failOnlyOnCall: 2)  // 2回目だけ失敗、3回目は成功
        let result = BookRenameExecutor.apply(rows: [row], fileManager: fm) { _, _ in }

        #expect(result.applied == 0)
        #expect(result.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: a.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.contains(".stacknest-rename-") })
    }

    @Test("巻き戻しにも失敗したら理由でそれと分かる")
    func stagingAndRollbackBothFail() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("abc.zip")
        try touch(a, "content")

        let row = RenamePlanRow(id: 1, oldPath: a.path,
                                newPath: dir.appendingPathComponent("ABC.zip").path,
                                oldName: "abc.zip", newName: "ABC.zip", status: .ok)
        let fm = FailingFileManager(failOnCallsFrom: 2)  // 2 回目以降全て失敗
        let result = BookRenameExecutor.apply(rows: [row], fileManager: fm) { _, _ in }

        #expect(result.applied == 0)
        #expect(result.failed.count == 1)
        #expect(result.failed[0].reason.contains(".stacknest-rename-"))
    }

    /// 指定した回数目の moveItem だけ失敗させる FileManager。
    private final class FailingFileManager: FileManager, @unchecked Sendable {
        private let failOnlyOnCall: Int?
        private let failOnCallsFrom: Int?
        private var calls = 0

        init(failOnlyOnCall: Int) {
            self.failOnlyOnCall = failOnlyOnCall
            self.failOnCallsFrom = nil
            super.init()
        }

        init(failOnCallsFrom: Int) {
            self.failOnlyOnCall = nil
            self.failOnCallsFrom = failOnCallsFrom
            super.init()
        }

        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            calls += 1
            var shouldFail = false
            if let only = failOnlyOnCall {
                shouldFail = calls == only
            } else if let from = failOnCallsFrom {
                shouldFail = calls >= from
            }
            if shouldFail {
                throw NSError(domain: "test", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "injected"])
            }
            try super.moveItem(at: srcURL, to: dstURL)
        }
    }
}
