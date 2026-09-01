// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
import StackroomFormat
@testable import StackNest

/// **GUI と MCP が同じ判断を返すこと**を押さえる（View そのものは組み立てない）。
@Suite("シートとエンドポイントの判断が一致する")
struct BookFileRenameSheetPlanTests {
    @Test("同じ入力からは同じ計画が出る")
    func sameInputSamePlan() throws {
        let rec = BookRecord(id: 1, title: "本", path: "/x/old.zip", dateAdded: Date(),
                             series: "シリーズ", volume: 7)
        let format = try FilenameFormat(raw: "@series v@volume")
        let widths = ["シリーズ": 3]
        let a = BookRenamePlanner.plan(books: [rec], format: format, bookTypeLabels: [:],
                                       volumeWidths: widths, fileExists: { _ in false })
        let b = BookRenamePlanner.plan(books: [rec], format: format, bookTypeLabels: [:],
                                       volumeWidths: widths, fileExists: { _ in false })
        #expect(a == b)
        #expect(a[0].newName == "シリーズ v007.zip")
    }

    /// smoke 修正 4（B6 自走確認）: GUI の呼び出し側（LibraryBrowserView.swift）は
    /// 「選択した本の series 名で問い合わせるが、桁は庫全体の最大巻から作る」という式を使う。
    /// ここではその**呼び出し側と同じ式**（`db.maxVolumeBySeries` → `VolumeWidth.widths`）で
    /// 桁を作り、改名対象が 1 冊だけでも庫全体の最大巻から桁が決まることを固定する。
    @Test("庫全体の最大巻から桁を作る経路（GUI の呼び出し側と同じ式）")
    func volumeWidthsFromDatabase() throws {
        let db = try Database.openInMemory()
        try db.migrate()
        // 同じシリーズに 7 巻と 100 巻。改名するのは 7 巻の 1 冊だけ。
        try db.insertBook(BookRecord(id: 1, title: "A", path: "/x/a.zip", dateAdded: Date(),
                                     series: "長編", volume: 7))
        try db.insertBook(BookRecord(id: 2, title: "B", path: "/x/b.zip", dateAdded: Date(),
                                     series: "長編", volume: 100))
        let books = try db.bookRows(ids: [1])          // ★ 改名対象は 1 冊だけ
        let widths = VolumeWidth.widths(
            fromMaxVolumes: try db.maxVolumeBySeries(books.compactMap { $0.series }))
        let rows = BookRenamePlanner.plan(
            books: books.map { $0.toRecord() },
            format: try FilenameFormat(raw: "@series v@volume"),
            bookTypeLabels: [:], volumeWidths: widths,
            oldFileExists: { _ in true }, fileExists: { _ in false })
        // 対象は 7 巻の 1 冊だけだが、**庫全体の最大が 100 なので 3 桁**になる。
        #expect(rows[0].newName == "長編 v007.zip")
    }
}
