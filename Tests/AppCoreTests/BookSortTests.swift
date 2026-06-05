// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@Suite("sortedByColumn — extracted column comparator")
struct BookSortTests {
    private func book(_ id: Int, title: String = "", rating: Int = 0, volume: Double? = nil, series: String? = nil, dateAdded: TimeInterval = 0) -> BookRow {
        BookRow(id: id, title: title, author: nil, genre: nil, path: nil,
                dateAdded: Date(timeIntervalSince1970: dateAdded), playDate: nil,
                bookType: 0, fileType: 0, pages: nil, rating: rating, unseen: true,
                keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil,
                series: series, volume: volume, coverImageName: nil, coverCropRect: nil,
                pageDirection: nil, contentHash: nil, fileSize: nil, fileMtime: nil)
    }

    @Test func titleAscending() {
        let books = [book(1, title: "C"), book(2, title: "A"), book(3, title: "B")]
        let sorted = books.sortedByColumn(ColumnSort(column: .title, ascending: true))
        #expect(sorted.map(\.id) == [2, 3, 1])
    }
    @Test func ratingDescending() {
        let books = [book(1, rating: 2), book(2, rating: 5), book(3, rating: 3)]
        let sorted = books.sortedByColumn(ColumnSort(column: .rating, ascending: false))
        #expect(sorted.map(\.id) == [2, 3, 1])
    }
    @Test func volumeAscendingNilLast() {
        let books = [book(1, volume: 2), book(2, volume: nil), book(3, volume: 1)]
        let sorted = books.sortedByColumn(ColumnSort(column: .volume, ascending: true))
        #expect(sorted.map(\.id) == [3, 1, 2])   // nil は +infinity 扱いで末尾
    }
}
