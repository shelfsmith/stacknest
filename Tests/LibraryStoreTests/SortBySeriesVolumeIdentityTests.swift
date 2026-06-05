// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("sortedBySeriesAndVolume — order identical to localizedStandardCompare reference")
struct SortBySeriesVolumeIdentityTests {
    private func mk(_ id: Int, _ series: String?, _ vol: Double?) -> BookRow {
        BookRow(id: id, title: "t\(id)", author: nil, genre: nil, path: nil,
                dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 0,
                pages: nil, rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil,
                neta: nil, memo: nil, series: series, volume: vol, coverImageName: nil,
                coverCropRect: nil, pageDirection: nil, contentHash: nil, fileSize: nil, fileMtime: nil)
    }
    /// 旧実装と同じ参照コンパレータ（series: localizedStandardCompare・NULL末尾 / volume数値昇順・同series内NULL先頭 / id昇順）
    private func reference(_ a: BookRow, _ b: BookRow) -> Bool {
        switch (a.series, b.series) {
        case (nil, nil): break
        case (nil, _): return false
        case (_, nil): return true
        case let (sa?, sb?):
            let c = sa.localizedStandardCompare(sb)
            if c != .orderedSame { return c == .orderedAscending }
        }
        switch (a.volume, b.volume) {
        case (nil, nil): return a.id < b.id
        case (nil, _): return true
        case (_, nil): return false
        case let (va?, vb?):
            if va != vb { return va < vb }
            return a.id < b.id
        }
    }

    @Test func matchesReferenceOnRandomData() {
        var rng = SplitMix64(seed: 33)
        let seriesPool: [String?] = ["シリーズ2","シリーズ10","シリーズ1","アキラ","ワンピース","ABC","abc",nil]
        let books = (1...500).map { id -> BookRow in
            let s = seriesPool[Int(rng.next() % UInt64(seriesPool.count))]
            let v: Double? = (rng.next() % 4 == 0) ? nil : Double(rng.next() % 20)
            return mk(id, s, v)
        }
        let new = books.sortedBySeriesAndVolume()
        let ref = books.sorted(by: reference)
        // id 厳密一致（reference は id tiebreak で全順序＝一意）
        #expect(new.map(\.id) == ref.map(\.id))
    }
}
