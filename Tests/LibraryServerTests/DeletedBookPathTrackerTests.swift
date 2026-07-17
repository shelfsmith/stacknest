// SPDX-License-Identifier: MIT
import Testing
@testable import LibraryServer

/// G16 Codex High fix: peek は非破壊、take は成功後に一度きり consume する。
/// 衝突で restoreBook が throw した場合に記録を失わないための不変条件を固定する。
@Suite("DeletedBookPathTracker")
struct DeletedBookPathTrackerTests {
    @Test func peekIsNonDestructiveTakeConsumes() async {
        let t = DeletedBookPathTracker()
        await t.record(uuid: "L", bookID: 1, path: "/lib/a.zip")

        // peek は何度呼んでも記録を消さない（restoreBook が throw しても path が残る）。
        #expect(await t.peek(uuid: "L", bookID: 1) == "/lib/a.zip")
        #expect(await t.peek(uuid: "L", bookID: 1) == "/lib/a.zip")

        // take は返しつつ削除する（一度きり）。
        #expect(await t.take(uuid: "L", bookID: 1) == "/lib/a.zip")
        #expect(await t.peek(uuid: "L", bookID: 1) == nil)
        #expect(await t.take(uuid: "L", bookID: 1) == nil)
    }

    @Test func keysAreIndependentPerLibraryAndBook() async {
        let t = DeletedBookPathTracker()
        await t.record(uuid: "L1", bookID: 1, path: "/x")
        await t.record(uuid: "L2", bookID: 1, path: "/y")
        #expect(await t.peek(uuid: "L1", bookID: 1) == "/x")
        #expect(await t.peek(uuid: "L2", bookID: 1) == "/y")
        #expect(await t.peek(uuid: "L1", bookID: 2) == nil)
    }
}
