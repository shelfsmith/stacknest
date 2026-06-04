// SPDX-License-Identifier: MIT
import Foundation

public extension Sequence where Element == BookRow {
    /// Sort by series (natural sort, NULL last) then by volume (numeric ascending,
    /// NULL first within the same series). Tiebreak by id ascending.
    func sortedBySeriesAndVolume() -> [BookRow] {
        sorted { a, b in
            // 1. series: NULL is sorted last
            switch (a.series, b.series) {
            case (nil, nil):
                break  // fall through to volume comparison
            case (nil, _):
                return false  // a (nil) goes after b
            case (_, nil):
                return true   // b (nil) goes after a
            case let (sa?, sb?):
                let cmp = sa.localizedStandardCompare(sb)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                // same series → fall through to volume comparison
            }
            // 2. Within the same series: NULL volume comes first
            switch (a.volume, b.volume) {
            case (nil, nil):
                return a.id < b.id  // tiebreak by id
            case (nil, _):
                return true         // a (nil volume) before b
            case (_, nil):
                return false        // b (nil volume) before a
            case let (va?, vb?):
                if va != vb { return va < vb }
                return a.id < b.id  // tiebreak by id
            }
        }
    }
}
