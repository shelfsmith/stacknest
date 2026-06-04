// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("Sort by series + volume")
struct SortBySeriesVolumeTests {
    @Test
    func sortsBySeriesAlphaThenVolumeNumeric() {
        let books = [
            makeBook(id: 1, series: "ワンピース", volume: 10.0),
            makeBook(id: 2, series: "ワンピース", volume: 2.0),
            makeBook(id: 3, series: "アキラ", volume: nil),
            makeBook(id: 4, series: nil, volume: nil),
            makeBook(id: 5, series: "ワンピース", volume: nil),  // NULL volume → 同 series 内で先頭
        ]
        let sorted = books.sortedBySeriesAndVolume()
        // expected: アキラ(3) → ワンピース[NULL vol, 5] → ワンピース[2.0, 2] → ワンピース[10.0, 1] → nil series(4)
        #expect(sorted.map(\.id) == [3, 5, 2, 1, 4])
    }

    @Test
    func sortIsStableForTies() {
        let books = [
            makeBook(id: 1, series: "A", volume: 1.0),
            makeBook(id: 2, series: "A", volume: 1.0),
            makeBook(id: 3, series: "A", volume: 1.0),
        ]
        let sorted = books.sortedBySeriesAndVolume()
        // 同 series 同 volume: id 昇順で tiebreak
        #expect(sorted.map(\.id) == [1, 2, 3])
    }

    @Test
    func naturalSortHandlesNumericsInSeriesName() {
        // 「シリーズ 10」と「シリーズ 2」を natural sort で比較すれば 2 < 10
        let books = [
            makeBook(id: 1, series: "シリーズ 10", volume: 1.0),
            makeBook(id: 2, series: "シリーズ 2", volume: 1.0),
        ]
        let sorted = books.sortedBySeriesAndVolume()
        #expect(sorted.map(\.id) == [2, 1])  // 2 < 10 via natural sort
    }

    private func makeBook(id: Int, series: String?, volume: Double?) -> BookRow {
        BookRow(id: id, title: "T\(id)", author: nil, genre: nil, path: nil,
                dateAdded: Date(), playDate: nil, bookType: 0, fileType: 2,
                pages: nil, rating: 0, unseen: true,
                keywordA: nil, keywordB: nil, keywordC: nil,
                neta: nil, memo: nil,
                series: series, volume: volume)
    }
}
