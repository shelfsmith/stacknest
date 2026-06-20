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

    @Test func seriesAscIsSeriesThenVolume() {
        // 4.2c-4: .series はリモート同様「シリーズ名 → 巻数」の2段ソート。
        // series は自然順(localizedStandardCompare)で非降順に並ぶ（タイブレーク非依存の不変条件）。
        var rng = SplitMix64(seed: 44)
        let books = (1...200).map { mk($0, randomString(&rng)) }
        let new = books.sortedByColumn(ColumnSort(column: .series, ascending: true))
        for i in 0..<(new.count - 1) {
            #expect((new[i].series ?? "").localizedStandardCompare(new[i+1].series ?? "") != .orderedDescending)
        }
        #expect(Set(new.map(\.id)) == Set(books.map(\.id)))
        #expect(new.count == books.count)
    }

    private func mkSV(_ id: Int, series: String, volume: Double?) -> BookRow {
        BookRow(id: id, title: "t\(id)", author: nil, genre: nil, path: nil,
                dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 0,
                pages: nil, rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil,
                neta: nil, memo: nil, series: series, volume: volume, coverImageName: nil,
                coverCropRect: nil, pageDirection: nil, contentHash: nil, fileSize: nil, fileMtime: nil)
    }

    @Test func seriesOrdersByVolumeWithinSeries() {
        // 4.2c-4: 同一シリーズ内は巻数昇順、シリーズ間は自然順(A<B、巻数は 1<2<10)。
        // 旧「シリーズ → 巻数」複合ソートを単一カラム「シリーズ」が内包する。
        let books = [
            mkSV(1, series: "B", volume: 1),
            mkSV(2, series: "A", volume: 10),
            mkSV(3, series: "A", volume: 2),
            mkSV(4, series: "A", volume: 1),
            mkSV(5, series: "B", volume: 2),
        ]
        let asc = books.sortedByColumn(ColumnSort(column: .series, ascending: true))
        #expect(asc.map(\.id) == [4, 3, 2, 1, 5])   // A1, A2, A10, B1, B2
        // 降順はリモート同様に全体を反転する。
        let desc = books.sortedByColumn(ColumnSort(column: .series, ascending: false))
        #expect(desc.map(\.id) == [5, 1, 2, 3, 4])
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
