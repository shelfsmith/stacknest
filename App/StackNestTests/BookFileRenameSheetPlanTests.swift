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
}
