// SPDX-License-Identifier: MIT
import Foundation

/// DSU helper for sortedBySeriesAndVolume.
private struct _SeriesVolumeDecorated {
    let seriesKey: [UInt8]?
    let volume: Double?
    let id: Int
    let book: BookRow
}

public extension Sequence where Element == BookRow {
    /// series（自然順・NULL 末尾）→ volume（数値昇順・同 series 内 NULL 先頭）→ id 昇順。
    /// series は localizedSortKey(numeric:true) の前計算キーで DSU（localizedStandardCompare と同順序）。
    func sortedBySeriesAndVolume() -> [BookRow] {
        let decorated: [_SeriesVolumeDecorated] = map { b in
            _SeriesVolumeDecorated(
                seriesKey: b.series.map { localizedSortKey($0, numeric: true) },
                volume: b.volume, id: b.id, book: b)
        }
        return decorated.sorted { a, b in
            switch (a.seriesKey, b.seriesKey) {
            case (nil, nil): break
            case (nil, _):   return false
            case (_, nil):   return true
            case let (sa?, sb?):
                if sa != sb { return sa.lexicographicallyPrecedes(sb) }
            }
            switch (a.volume, b.volume) {
            case (nil, nil): return a.id < b.id
            case (nil, _):   return true
            case (_, nil):   return false
            case let (va?, vb?):
                if va != vb { return va < vb }
                return a.id < b.id
            }
        }.map(\.book)
    }
}
