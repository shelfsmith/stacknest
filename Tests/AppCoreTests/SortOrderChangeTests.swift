// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@Suite("sortOrderAffected — 再ソート要否判定")
struct SortOrderChangeTests {
    private func book(
        _ id: Int, title: String = "T", rating: Int = 0, unseen: Bool = true,
        playDate: Date? = nil, dateAdded: TimeInterval = 0,
        series: String? = nil, volume: Double? = nil
    ) -> BookRow {
        BookRow(id: id, title: title, author: nil, genre: nil, path: nil,
                dateAdded: Date(timeIntervalSince1970: dateAdded), playDate: playDate,
                bookType: 0, fileType: 0, pages: nil, rating: rating, unseen: unseen,
                keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil,
                series: series, volume: volume, coverImageName: nil, coverCropRect: nil,
                pageDirection: nil, contentHash: nil, fileSize: nil, fileMtime: nil)
    }

    // 読書が変える列でソート中 → 再ソート必要
    @Test func playDateChangedUnderPlayDateSort() {
        let old = book(1, playDate: nil)
        let new = book(1, playDate: Date(timeIntervalSince1970: 100))
        #expect(sortOrderAffected(old: old, new: new,
            sortMode: .column, columnSort: ColumnSort(column: .playDate, ascending: false)) == true)
    }
    @Test func unseenChangedUnderUnseenSort() {
        let old = book(1, unseen: true)
        let new = book(1, unseen: false)
        #expect(sortOrderAffected(old: old, new: new,
            sortMode: .column, columnSort: ColumnSort(column: .unseen, ascending: true)) == true)
    }

    // 読書が変える列だが別列でソート中 → 再ソート不要
    @Test func playDateChangedUnderTitleSort() {
        let old = book(1, title: "A", playDate: nil)
        let new = book(1, title: "A", playDate: Date(timeIntervalSince1970: 100))
        #expect(sortOrderAffected(old: old, new: new,
            sortMode: .column, columnSort: ColumnSort(column: .title, ascending: true)) == false)
    }

    // ソートキーそのものが変化 → 再ソート必要
    @Test func titleChangedUnderTitleSort() {
        #expect(sortOrderAffected(old: book(1, title: "A"), new: book(1, title: "B"),
            sortMode: .column, columnSort: ColumnSort(column: .title, ascending: true)) == true)
    }

    // series/volume モード: 読書では series/volume 不変 → 不要
    @Test func seriesVolumeModeUnaffectedByReading() {
        let old = book(1, unseen: true, playDate: nil, series: "S", volume: 1)
        let new = book(1, unseen: false, playDate: Date(timeIntervalSince1970: 100), series: "S", volume: 1)
        #expect(sortOrderAffected(old: old, new: new,
            sortMode: .seriesVolumeAsc, columnSort: ColumnSort(column: .title, ascending: true)) == false)
    }
    @Test func seriesVolumeModeVolumeChanged() {
        let old = book(1, series: "S", volume: 1)
        let new = book(1, series: "S", volume: 2)
        #expect(sortOrderAffected(old: old, new: new,
            sortMode: .seriesVolumeDesc, columnSort: ColumnSort(column: .title, ascending: true)) == true)
    }
}
