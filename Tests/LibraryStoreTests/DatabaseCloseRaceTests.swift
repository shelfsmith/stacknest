// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// G35 Codex 4 巡目 P1: `Database.close()` と、オフスレッドからの読み取りの競合。
///
/// G35 で監視フォルダの走査（`allBookPaths`）がメインスレッドの外へ移った結果、
/// **`close()` が `queue = nil` を書くのと並行して `queue` が読まれる**ようになった。
/// 従来は読み手も書き手も MainActor 上にいたので起こり得なかった。
///
/// これは論理的な競合では済まない ―― strong reference の並行読み書きは
/// **ARC の retain/release が壊れうる**ため、メモリ安全性の問題になる。
///
/// **このテストは Thread Sanitizer で走らせて意味がある**:
/// ```
/// swift test --sanitize=thread --filter DatabaseCloseRaceTests
/// ```
/// ロックを外すと TSan が `Swift.Optional<GRDB.DatabaseQueue>` への
/// write/read レースを報告する（実際に確認済み）。
@Suite("Database.close() と並行読み取り（G35 Codex P1）")
struct DatabaseCloseRaceTests {

    private func seeded() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        for i in 1...20 {
            try db.insertBook(BookRow(
                id: i, title: "B\(i)", author: nil, genre: nil, path: "/p/\(i).zip",
                dateAdded: Date(timeIntervalSince1970: 0), playDate: nil,
                bookType: 0, fileType: 2, pages: nil, rating: 0, unseen: true,
                keywordA: nil, keywordB: nil, keywordC: nil, neta: nil))
        }
        return db
    }

    /// 監視フォルダの走査が読んでいる最中にライブラリが閉じられる、という実際の並びを再現する
    /// （`AppState.closeBundle` は `folderWatcher.stop()` → `database.close()` の順で、
    /// 走査は detached タスクで走り続けている）。
    @Test("close() と並行して allBookPaths を読んでも壊れない")
    func closeWhileReadingPaths() async throws {
        for _ in 0..<40 {
            let db = try seeded()

            let reader = Task.detached(priority: .utility) {
                // 閉じられるまで読み続ける。閉じたあとは空集合が返るだけで、
                // 例外もクラッシュも起きてはならない。
                for _ in 0..<50 {
                    _ = try? db.allBookPaths()
                }
            }
            // 読み手が走っている最中に閉じる
            db.close()
            await reader.value

            #expect(try db.allBookPaths().isEmpty, "閉じた後は空集合")
        }
    }

    /// `fetchAllBooks`（従来からオフスレッドで呼ばれうる経路。`BookImporter` 経由）も同じ。
    @Test("close() と並行して fetchAllBooks を読んでも壊れない")
    func closeWhileFetchingBooks() async throws {
        for _ in 0..<40 {
            let db = try seeded()

            let reader = Task.detached(priority: .utility) {
                for _ in 0..<50 {
                    _ = try? db.fetchAllBooks()
                }
            }
            db.close()
            await reader.value

            #expect(try db.fetchAllBooks().isEmpty)
        }
    }

    /// 複数の読み手が同時に走っている状態で閉じる（走査は庫ごとに走るため、
    /// 実運用でも複数のオフスレッド読み手が居うる）。
    @Test("複数の並行読み手が居ても close() で壊れない")
    func closeWithSeveralConcurrentReaders() async throws {
        for _ in 0..<20 {
            let db = try seeded()

            let readers = (0..<4).map { _ in
                Task.detached(priority: .utility) {
                    for _ in 0..<40 { _ = try? db.allBookPaths() }
                }
            }
            db.close()
            for r in readers { await r.value }

            #expect(try db.allBookPaths().isEmpty)
        }
    }
}
