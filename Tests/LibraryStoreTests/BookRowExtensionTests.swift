// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("BookRow series/volume extension")
struct BookRowExtensionTests {
    @Test
    func bookRowHasSeriesAndVolumeProperties() {
        let row = BookRow(
            id: 1, title: "ワンピース 第5巻", author: nil, genre: nil,
            path: nil, dateAdded: Date(), playDate: nil,
            bookType: 0, fileType: 2, pages: nil, rating: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil,
            neta: nil, memo: nil,
            series: "ワンピース", volume: 5.0
        )
        #expect(row.series == "ワンピース")
        #expect(row.volume == 5.0)
    }

    @Test
    func bookPatchHasSeriesAndVolumeFields() {
        let patch = BookPatch(series: "ワンピース", volume: 5.0)
        #expect(patch.series == "ワンピース")
        #expect(patch.volume == 5.0)
        #expect(!patch.isEmpty)
    }

    @Test
    func bookRowDefaultsToNilSeriesAndVolume() {
        // 既存 callsite の互換性確認: series/volume を省略しても compile / 動作
        let row = BookRow(
            id: 1, title: "Untitled", author: nil, genre: nil,
            path: nil, dateAdded: Date(), playDate: nil,
            bookType: 0, fileType: 2, pages: nil, rating: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil,
            neta: nil, memo: nil
        )
        #expect(row.series == nil)
        #expect(row.volume == nil)
    }
}
