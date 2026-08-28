// SPDX-License-Identifier: MIT
import Testing
import Foundation
import StackroomFormat
@testable import LibraryStore

@Suite("BookRow → BookRecord")
struct BookRowRecordTests {
    @Test("series と volume が落ちない")
    func carriesSeriesAndVolume() {
        let row = BookRow(
            id: 1, title: "本", author: "著", genre: nil, path: "/tmp/a.zip",
            dateAdded: Date(), playDate: nil, bookType: 0, fileType: 2, pages: nil,
            rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: "KC",
            neta: nil, memo: nil, series: "シリーズ", volume: 7,
            coverImageName: nil, coverCropRect: nil, pageDirection: nil,
            contentHash: nil, fileSize: nil, fileMtime: nil)
        let rec = row.toRecord()
        #expect(rec.series == "シリーズ")
        #expect(rec.volume == 7)
        #expect(rec.keywordC == "KC")
        #expect(rec.myRate == 0)
    }
}
