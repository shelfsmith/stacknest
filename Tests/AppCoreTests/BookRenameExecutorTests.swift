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

    /// Codex レビュー P1: 大文字小文字だけの改名が成功した後に `updatePath` が投げると、
    /// 巻き戻し（新名 → 旧名）も「大文字小文字だけ違う」move になる。これも一時名を
    /// 経由しないと「既に存在する」で落ち、ファイルは新名のまま・DB は旧名のままという
    /// 食い違いが残っていた（まさに修正 2 で塞いだはずの状態）。
    ///
    /// **この開発機の実ファイルシステムでは、大文字小文字だけの直接 move が偶然成功してしまい**
    /// （実測済み）、実 FileManager だけでは修正前後の違いを再現できない。`CaseCollisionFileManager`
    /// で「大文字小文字だけ違う直接 move」だけを確実に失敗させ、コードが一時名を経由する分岐を
    /// 通ることを固定する（`FailingFileManager` が call 番号でステージング内部の失敗を再現するのと
    /// 同じ考え方）。
    @Test("★ 大文字小文字だけの改名で updatePath が投げても、元の名前に戻る")
    func caseOnlyRenameRollsBackWhenUpdateThrows() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("abc.zip")
        try touch(a, "本体")
        struct E: Error {}
        let row = RenamePlanRow(id: 1, oldPath: a.path,
                                newPath: dir.appendingPathComponent("ABC.zip").path,
                                oldName: "abc.zip", newName: "ABC.zip", status: .ok)
        let fm = CaseCollisionFileManager()
        let result = BookRenameExecutor.apply(rows: [row], fileManager: fm) { _, _ in throw E() }

        #expect(result.applied == 0)
        #expect(result.failed.count == 1)
        // ★ 元の名前に戻っていること（大文字小文字まで一致）。ステージングを経由せず
        //   直接 move だけで戻そうとすると、この fake の上では必ず失敗する。
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["abc.zip"])
        #expect(try String(contentsOf: a, encoding: .utf8) == "本体")
    }

    /// smoke 修正 5（D1 自走確認）: 計画（`plan`）の時点では宛先が無かったのに、
    /// 実行（`apply`）の直前に誰かが同じ名前のファイルを作ってしまった場合でも、
    /// 双方のファイルが壊れない/失われないことを固定する。
    @Test("計画の後に宛先が生まれても、ファイルは壊れない")
    func conflictAppearsAfterPlanning() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.zip")
        try touch(a, "本体")
        // 計画時点では宛先が無かったので ok。
        let row = RenamePlanRow(id: 1, oldPath: a.path,
                                newPath: dir.appendingPathComponent("新.zip").path,
                                oldName: "a.zip", newName: "新.zip", status: .ok)
        // 実行の直前に、誰かが同じ名前のファイルを作った。
        try touch(dir.appendingPathComponent("新.zip"), "先客")

        let result = BookRenameExecutor.apply(rows: [row]) { _, _ in }

        #expect(result.applied == 0)
        #expect(result.failed.count == 1)
        // ★ どちらのファイルも失われていない。
        #expect(try String(contentsOf: a, encoding: .utf8) == "本体")
        #expect(try String(contentsOf: dir.appendingPathComponent("新.zip"), encoding: .utf8) == "先客")
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

    /// 大文字小文字だけ違う直接 move だけを「既に存在する」で失敗させる FileManager。
    ///
    /// **実測（2026-09-01）で判明**: 実ファイルシステムでは大文字小文字だけの直接 move は
    /// **成功してしまう** —— 起動ディスク（APFS）でも `/Volumes/comic` 等（HFS+）でも同じ。
    /// つまり `caseAwareMove` の一時名経由の分岐（`from`→`to` が大文字小文字だけ違う場合）は、
    /// **この fake が無いと実 FileManager では一度も試験できない**（直接 move が通ってしまうため
    /// ステージングの成功/失敗パスに到達しない）。この fake がその経路を確実に踏ませ、
    /// `caseOnlyRenameRollsBackWhenUpdateThrows` を修正前後で意味のある回帰テストにしている。
    /// ステージング用の一時名は大文字小文字以外の差分（UUID 付き）を持つため、この fake では素通りする。
    private final class CaseCollisionFileManager: FileManager, @unchecked Sendable {
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if srcURL.path != dstURL.path, srcURL.path.lowercased() == dstURL.path.lowercased() {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                              userInfo: [NSLocalizedDescriptionKey: "既に存在します"])
            }
            try super.moveItem(at: srcURL, to: dstURL)
        }
    }
}
