// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

public extension Array where Element == BookRow {
    /// 列ソート。文字列列は localizedSortKey の前計算キーで DSU、数値/日付/bool は直接比較（挙動不変）。
    func sortedByColumn(_ sort: ColumnSort) -> [BookRow] {
        let asc = sort.ascending

        // series 列はリモート(BookSortKey.series)と同じく「シリーズ名 → 巻数」の2段ソートにする。
        // 単一カラム「シリーズ」を選ぶだけで同一シリーズ内が巻数順になるため、旧「シリーズ → 巻数」
        // 複合ソート(.seriesVolume*)は不要になり UI から廃止した。降順はリモート同様に全体を反転する。
        if sort.column == .series {
            let bySeriesVolume = sortedBySeriesAndVolume()
            return asc ? bySeriesVolume : Array(bySeriesVolume.reversed())
        }

        // 文字列列は DSU（前計算キーのバイト比較）
        let stringValue: ((BookRow) -> String)?
        switch sort.column {
        case .title:    stringValue = { $0.title }
        case .author:   stringValue = { $0.author ?? "" }
        case .genre:    stringValue = { $0.genre ?? "" }
        case .neta:     stringValue = { $0.neta ?? "" }
        case .keywordA: stringValue = { $0.keywordA ?? "" }
        case .keywordB: stringValue = { $0.keywordB ?? "" }
        case .memo:     stringValue = { $0.memo ?? "" }
        default:        stringValue = nil
        }
        if let extract = stringValue {
            let decorated = map { (key: localizedSortKey(extract($0), numeric: false), book: $0) }
            let sorted = decorated.sorted { a, b in
                asc ? a.key.lexicographicallyPrecedes(b.key) : b.key.lexicographicallyPrecedes(a.key)
            }
            return sorted.map(\.book)
        }

        // 数値/日付/bool 列は直接比較（従来どおり・高速）
        return sorted { a, b in
            switch sort.column {
            case .rating:    return asc ? a.rating < b.rating : a.rating > b.rating
            case .bookType:  return asc ? a.bookType < b.bookType : a.bookType > b.bookType
            case .unseen:    return asc ? (!a.unseen && b.unseen) : (a.unseen && !b.unseen)
            case .dateAdded: return asc ? a.dateAdded < b.dateAdded : a.dateAdded > b.dateAdded
            case .playDate:
                let ad = a.playDate ?? Date(timeIntervalSince1970: 0)
                let bd = b.playDate ?? Date(timeIntervalSince1970: 0)
                return asc ? ad < bd : ad > bd
            case .volume:
                let av = a.volume ?? (asc ? .infinity : -.infinity)
                let bv = b.volume ?? (asc ? .infinity : -.infinity)
                return asc ? av < bv : av > bv
            default: return false   // 文字列列は上で処理済（到達しない）
            }
        }
    }
}
