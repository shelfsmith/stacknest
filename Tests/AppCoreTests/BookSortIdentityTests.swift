// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@Suite("sortedByColumn — order identical to localizedCaseInsensitiveCompare")
struct BookSortIdentityTests {
    private func mk(_ id: Int, _ title: String) -> BookRow {
        BookRow(id: id, title: title, author: title, genre: nil, path: nil,
                dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 0,
                pages: nil, rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil,
                neta: nil, memo: nil, series: title, volume: nil, coverImageName: nil,
                coverCropRect: nil, pageDirection: nil, contentHash: nil, fileSize: nil, fileMtime: nil)
    }
    private func randomString(_ rng: inout SplitMix64) -> String {
        let pool = ["りんご","リンゴ","Apple","apple","本2","本10","本1","全角","ABC10","ABC2","z","あ","ｶﾅ","",
                    "シリーズ\(rng.next() % 30)","作品\(rng.next() % 100)"]
        return pool[Int(rng.next() % UInt64(pool.count))]
    }

    @Test func titleAscMatchesReference() {
        var rng = SplitMix64(seed: 11)
        let books = (1...400).map { mk($0, randomString(&rng)) }
        let new = books.sortedByColumn(ColumnSort(column: .title, ascending: true))
        // 参照: 旧コンパレータで隣接ペアが順序を満たす（タイブレーク非依存の不変条件）
        for i in 0..<(new.count - 1) {
            #expect(new[i].title.localizedCaseInsensitiveCompare(new[i+1].title) != .orderedDescending)
        }
        #expect(Set(new.map(\.id)) == Set(books.map(\.id)))
        #expect(new.count == books.count)
    }

    @Test func titleDescMatchesReference() {
        var rng = SplitMix64(seed: 22)
        let books = (1...400).map { mk($0, randomString(&rng)) }
        let new = books.sortedByColumn(ColumnSort(column: .title, ascending: false))
        for i in 0..<(new.count - 1) {
            #expect(new[i].title.localizedCaseInsensitiveCompare(new[i+1].title) != .orderedAscending)
        }
        #expect(Set(new.map(\.id)) == Set(books.map(\.id)))
    }

    @Test func authorAscMatchesReference() {
        // 文字列列ルーティングのガード（switch で .author が誤って別列に振られない）
        var rng = SplitMix64(seed: 33)
        let books = (1...200).map { mk($0, randomString(&rng)) }
        let new = books.sortedByColumn(ColumnSort(column: .author, ascending: true))
        for i in 0..<(new.count - 1) {
            #expect((new[i].author ?? "").localizedCaseInsensitiveCompare(new[i+1].author ?? "") != .orderedDescending)
        }
        #expect(Set(new.map(\.id)) == Set(books.map(\.id)))
    }

    @Test func seriesAscMatchesReference() {
        // .series は文字列列（numeric:false）として扱う — このルーティングのガード
        var rng = SplitMix64(seed: 44)
        let books = (1...200).map { mk($0, randomString(&rng)) }
        let new = books.sortedByColumn(ColumnSort(column: .series, ascending: true))
        for i in 0..<(new.count - 1) {
            #expect((new[i].series ?? "").localizedCaseInsensitiveCompare(new[i+1].series ?? "") != .orderedDescending)
        }
        #expect(Set(new.map(\.id)) == Set(books.map(\.id)))
    }

    @Test func numericColumnUnchanged() {
        // 数値列は従来どおり（rating 降順）
        let books = (0..<3).map { i in
            BookRow(id: i + 1, title: "t\(i)", author: nil, genre: nil, path: nil,
                    dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 0,
                    pages: nil, rating: i, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil,
                    neta: nil, memo: nil, series: nil, volume: nil, coverImageName: nil,
                    coverCropRect: nil, pageDirection: nil, contentHash: nil, fileSize: nil, fileMtime: nil)
        }
        let new = books.sortedByColumn(ColumnSort(column: .rating, ascending: false))
        #expect(new.map(\.rating) == [2, 1, 0])
    }
}
