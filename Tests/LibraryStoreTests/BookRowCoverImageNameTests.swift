// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("BookRow / BookPatch cover_image_name extension")
struct BookRowCoverImageNameTests {
    @Test
    func bookRowHasCoverImageNameProperty() {
        let row = BookRow(
            id: 1, title: "T", author: nil, genre: nil,
            path: nil, dateAdded: Date(), playDate: nil,
            bookType: 0, fileType: 2, pages: nil, rating: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil,
            neta: nil, memo: nil,
            series: nil, volume: nil,
            coverImageName: "page05.jpg"
        )
        #expect(row.coverImageName == "page05.jpg")
    }

    @Test
    func bookPatchHasCoverImageNameAndClear() {
        let setPatch = BookPatch(coverImageName: "page05.jpg")
        #expect(setPatch.coverImageName == "page05.jpg")
        #expect(setPatch.clearCoverImageName == false)
        #expect(!setPatch.isEmpty)

        let clearPatch = BookPatch(clearCoverImageName: true)
        #expect(clearPatch.coverImageName == nil)
        #expect(clearPatch.clearCoverImageName == true)
        #expect(!clearPatch.isEmpty)
    }

    @Test
    func bookRowDefaultsToNilCoverImageName() {
        let row = BookRow(
            id: 1, title: "T", author: nil, genre: nil,
            path: nil, dateAdded: Date(), playDate: nil,
            bookType: 0, fileType: 2, pages: nil, rating: 0, unseen: true,
            keywordA: nil, keywordB: nil, keywordC: nil,
            neta: nil, memo: nil
        )
        #expect(row.coverImageName == nil)
    }
}
