// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@Suite("keywordC 列化")
struct KeywordCColumnTests {
    @Test func bookColumnHasKeywordC() {
        #expect(BookColumn.allCases.contains(.keywordC))
        #expect(BookColumn.keywordC.rawValue == "keyword_c")
        #expect(BookColumn.keywordC.serverSortKey == "keywordC")
        #expect(BookColumn.keywordC.wireField == "keywordC")
        #expect(BookColumn.keywordC.localizedTitleString == "キーワード C")
    }

    private func mk(_ id: Int, keywordC: String?) -> BookRow {
        BookRow(id: id, title: "T\(id)", author: nil, genre: nil, path: nil,
                dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 0,
                pages: nil, rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: keywordC,
                neta: nil, memo: nil, series: nil, volume: nil, coverImageName: nil,
                coverCropRect: nil, pageDirection: nil, contentHash: nil, fileSize: nil, fileMtime: nil)
    }

    @Test func sortedByColumnKeywordCOrders() {
        let books = [mk(1, keywordC: "C"), mk(2, keywordC: "A"), mk(3, keywordC: "B")]
        let asc = books.sortedByColumn(ColumnSort(column: .keywordC, ascending: true))
        for i in 0..<(asc.count - 1) {
            #expect((asc[i].keywordC ?? "").localizedStandardCompare(asc[i+1].keywordC ?? "") != .orderedDescending)
        }
        #expect(Set(asc.map(\.id)) == Set(books.map(\.id)))
    }

    @Test func sortOrderAffectedKeywordC() {
        let old = mk(1, keywordC: "A"); let new = mk(1, keywordC: "B")
        #expect(sortOrderAffected(old: old, new: new,
            sortMode: .column, columnSort: ColumnSort(column: .keywordC, ascending: true)) == true)
    }
}
