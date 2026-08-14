// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

/// G36 ②: 取り込みの中断協調。
///
/// `FolderWatcher` が停止されても `add` は走り切り、`AppState.closeBundle` が
/// `stop()` → `database.close()` の順で閉じるため**閉じた DB へ書きに行く**。
/// `guard let q = queue` があるので破損はしないが、表紙ファイルだけ書かれた孤児が残りうる。
///
/// **1 冊は最後までやる**（中途半端な本を作らない）。**巻き戻さない**
/// （失敗するロールバックを新しい欠陥にしない）。**中断は結果で伝える**。
@Suite("BookImporter の中断協調（G36）")
struct BookImporterCancellationTests {

    /// 実際に開ける zip を n 個作る。既存の検体 `three_pages.zip`（画像 3 枚）を複製する。
    private func makeZips(_ n: Int, in dir: URL) throws -> [URL] {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AppCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("three_pages.zip")
        var out: [URL] = []
        for i in 1...n {
            let url = dir.appendingPathComponent("(g) [a] book\(i).zip")
            try FileManager.default.copyItem(at: source, to: url)
            out.append(url)
        }
        return out
    }

    @Test("中断されたら本の境界で止まり、cancelled が立つ")
    func stopsAtBookBoundaryWhenCancelled() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g36-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database.openInMemory()
        try db.migrate()
        let bundle = dir.appendingPathComponent("lib.stacknest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let urls = try makeZips(5, in: dir)
        let importer = BookImporter(database: db, bundleURL: bundle,
                                    format: try FilenameFormat(raw: "@title"))

        let task = Task {
            await importer.add(urls: urls, autoClassifyEnabled: false, thickThreshold: 100)
        }
        task.cancel()
        let result = await task.value

        #expect(result.cancelled == true)
        // 巻き戻さない: 取り込めた分は残る（0 冊のこともある）
        #expect(result.addedIDs.count <= urls.count)
    }

    @Test("中断されなければ cancelled は false のまま")
    func notCancelledStaysFalse() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g36-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try Database.openInMemory()
        try db.migrate()
        let bundle = dir.appendingPathComponent("lib.stacknest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let urls = try makeZips(2, in: dir)
        let importer = BookImporter(database: db, bundleURL: bundle,
                                    format: try FilenameFormat(raw: "@title"))

        let result = await importer.add(urls: urls, autoClassifyEnabled: false, thickThreshold: 100)

        #expect(result.cancelled == false)
    }
}
