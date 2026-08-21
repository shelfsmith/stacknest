// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("Finder タグの読み書き（G39）")
struct FinderTagStoreTests {
    private func tempFile() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g39-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("book.zip")
        try Data("x".utf8).write(to: f)
        return f
    }

    /// xattr が**実在するか**を実装から独立に確かめる（`FinderTagStore.read` は空配列の
    /// plist と「属性そのものが無い」を同じ `[]` に潰すので、read では区別できない）。
    private func hasTagAttribute(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0) >= 0
        }
    }

    @Test func readsNothingFromAnUntaggedFile() throws {
        let f = try tempFile(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        #expect(try FinderTagStore.read(at: f).isEmpty)
    }

    @Test func writesAndReadsBack() throws {
        let f = try tempFile(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        try FinderTagStore.write([FinderTagEntry(name: "レッド", colorIndex: 6),
                                  FinderTagEntry(name: "あとで読む", colorIndex: nil)], to: f)
        let back = try FinderTagStore.read(at: f)
        #expect(Set(back.map(\.name)) == ["レッド", "あとで読む"])
        #expect(back.first { $0.name == "レッド" }?.colorIndex == 6)
        #expect(back.first { $0.name == "あとで読む" }?.colorIndex == nil)
    }

    /// ★★ 最重要。**書き戻しで既存タグの色が消えてはいけない。**
    @Test func applyKeepsTheColourOfTagsThatSurvive() throws {
        let f = try tempFile(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        try FinderTagStore.write([FinderTagEntry(name: "レッド", colorIndex: 6)], to: f)

        try FinderTagStore.apply(names: ["レッド", "新規"], to: f)

        let back = try FinderTagStore.read(at: f)
        #expect(back.first { $0.name == "レッド" }?.colorIndex == 6, "既存タグの色を落としてはいけない")
        #expect(back.first { $0.name == "新規" }?.colorIndex == nil, "新しいタグは色無し")
    }

    @Test func applyRemovesTagsThatAreGone() throws {
        let f = try tempFile(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        try FinderTagStore.write([FinderTagEntry(name: "a", colorIndex: 1),
                                  FinderTagEntry(name: "b", colorIndex: nil)], to: f)
        try FinderTagStore.apply(names: ["a"], to: f)
        #expect(Set(try FinderTagStore.read(at: f).map(\.name)) == ["a"])
    }

    /// 空集合を書いたら xattr ごと消えること（空配列の plist を残さない）。
    @Test func applyingAnEmptySetClearsTheAttribute() throws {
        let f = try tempFile(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        try FinderTagStore.write([FinderTagEntry(name: "a", colorIndex: nil)], to: f)
        try FinderTagStore.apply(names: [], to: f)
        #expect(try FinderTagStore.read(at: f).isEmpty)
        // read だけでは「空配列の plist が残っている」状態を見逃す（変異検証で実証済み）。
        #expect(hasTagAttribute(f) == false, "空配列の plist を残さず、xattr ごと消えること")
    }

    /// spec §3.4: フォルダにもタグは付く。**本 = フォルダの場合に特別扱いが要らない**根拠。
    @Test func worksOnADirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g39-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FinderTagStore.apply(names: ["フォルダ本"], to: dir)
        #expect(Set(try FinderTagStore.read(at: dir).map(\.name)) == ["フォルダ本"])
    }

    // MARK: - 実 I/O の落とし穴（brief の 6 件に加えて自前で確認したもの）

    /// `getxattr` は「サイズを問う」→「読む」の 2 回呼び。**その間に Finder がタグを変えると
    /// サイズが食い違い、伸びた場合は `ERANGE` で失敗する。**読みが例外で落ちないこと。
    @Test func readSurvivesTagsChangingUnderneathIt() throws {
        let f = try tempFile(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }

        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
            func set() { lock.lock(); value = true; lock.unlock() }
        }

        let stop = Flag()
        let url = f
        let short = [FinderTagEntry(name: "a", colorIndex: nil)]
        let long = (0..<40).map {
            FinderTagEntry(name: "tag-\($0)-" + String(repeating: "x", count: 40), colorIndex: 3)
        }
        Thread.detachNewThread {
            var i = 0
            while !stop.isSet && i < 100_000 {
                try? FinderTagStore.write(i.isMultiple(of: 2) ? short : long, to: url)
                i += 1
            }
        }
        defer { stop.set() }

        var reads = 0
        for _ in 0..<500 {
            // 例外が飛んだらここでテストが落ちる（＝ERANGE を握れていない）。
            // 中身は検査しない: setxattr の置換は原子的でなく、書き換えの隙間で
            // ENOATTR（＝タグ 0 件）が実際に観測される（実測 500 回中 18 回）。
            _ = try FinderTagStore.read(at: url)
            reads += 1
        }
        #expect(reads == 500)
    }

    /// 書き込み権限が無いファイルでの失敗を**握り潰さない**こと。
    @Test func surfacesAPermissionFailureInsteadOfSwallowingIt() throws {
        guard geteuid() != 0 else { return }  // root は権限検査を素通りするので検証にならない
        let f = try tempFile(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: f.path)

        #expect(throws: FinderTagError.xattrFailed(errno: EACCES, path: f.path)) {
            try FinderTagStore.write([FinderTagEntry(name: "x", colorIndex: nil)], to: f)
        }
    }

    /// シンボリックリンク越しでも**リンク先の実ファイル**のタグを読み書きすること
    /// （`xattr(1)` と Finder の既定に揃える）。読みと書きで挙動が食い違うと片方だけ効く。
    @Test func followsASymlinkToTheRealFile() throws {
        let f = try tempFile(); defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let link = f.deletingLastPathComponent().appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f)

        try FinderTagStore.apply(names: ["リンク経由"], to: link)

        #expect(Set(try FinderTagStore.read(at: f).map(\.name)) == ["リンク経由"])
        #expect(Set(try FinderTagStore.read(at: link).map(\.name)) == ["リンク経由"])
    }
}
