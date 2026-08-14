// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@MainActor
@Suite("LibrarySettings.gridItemSize")
struct LibrarySettingsGridSizeTests {
    private func makeFreshDB() throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gridsize_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database.openFile(at: dir.appendingPathComponent("library.sqlite"), mode: .createOrReplace)
        try db.migrate()
        return db
    }

    @Test
    func defaultIs160() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        #expect(s.gridItemSize == 160)
    }

    @Test
    func persistsAndReloads() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        s.gridItemSize = 220
        // G36 ③: gridItemSize は Slider に直結していてドラッグ中ずっと発火するので、
        // 書き込みはデバウンスされる。別インスタンスで読む前に確定させる。
        s.flushPendingWrites()
        let r = try LibrarySettings(database: db)
        #expect(r.gridItemSize == 220)
    }

    /// ★ デバウンスが実際に効いていることの証拠。flush しなければ「まだ default のまま」
    /// 読める必要がある。これが無いと「デバウンスされていないのにテストが通る」状態と
    /// 区別できない（＝上の `persistsAndReloads` が偶然通っているだけかもしれない）。
    ///
    /// タイマは 500ms 後に発火するデフォルト interval なので、`schedule` 直後・同一スレッド上
    /// で同期的に読む限り、固定 sleep なしで確実に「まだ書かれていない」状態を観測できる
    /// （dispatch のタイマは早倒しでは発火しない）。
    @Test
    func doesNotPersistUntilFlushed() throws {
        let db = try makeFreshDB()
        let s = try LibrarySettings(database: db)
        s.gridItemSize = 220

        // flush していない: 同じ db を共有する別インスタンスで読んでも、
        // ディスク上はまだ default (160) のまま。
        let before = try LibrarySettings(database: db)
        #expect(before.gridItemSize == 160, "flush 前はまだデバウンス待ちで、ディスク上は default のまま")

        s.flushPendingWrites()

        let after = try LibrarySettings(database: db)
        #expect(after.gridItemSize == 220, "flush 後は確実にディスクへ反映されている")
    }
}
