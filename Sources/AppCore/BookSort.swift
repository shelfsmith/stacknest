// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

public extension Array where Element == BookRow {
    /// 列ソート。AppState.bookSortComparator から抽出した純関数（挙動不変）。
    func sortedByColumn(_ sort: ColumnSort) -> [BookRow] {
        let asc = sort.ascending
        func cmpStr(_ a: String, _ b: String) -> Bool {
            let c = a.localizedCaseInsensitiveCompare(b)
            return asc ? c == .orderedAscending : c == .orderedDescending
        }
        return sorted { a, b in
            switch sort.column {
            case .title:     return cmpStr(a.title, b.title)
            case .author:    return cmpStr(a.author ?? "", b.author ?? "")
            case .genre:     return cmpStr(a.genre ?? "", b.genre ?? "")
            case .neta:      return cmpStr(a.neta ?? "", b.neta ?? "")
            case .keywordA:  return cmpStr(a.keywordA ?? "", b.keywordA ?? "")
            case .keywordB:  return cmpStr(a.keywordB ?? "", b.keywordB ?? "")
            case .memo:      return cmpStr(a.memo ?? "", b.memo ?? "")
            case .rating:    return asc ? a.rating < b.rating : a.rating > b.rating
            case .bookType:  return asc ? a.bookType < b.bookType : a.bookType > b.bookType
            case .unseen:    return asc ? (!a.unseen && b.unseen) : (a.unseen && !b.unseen)
            case .dateAdded: return asc ? a.dateAdded < b.dateAdded : a.dateAdded > b.dateAdded
            case .playDate:
                let ad = a.playDate ?? Date(timeIntervalSince1970: 0)
                let bd = b.playDate ?? Date(timeIntervalSince1970: 0)
                return asc ? ad < bd : ad > bd
            case .series:    return cmpStr(a.series ?? "", b.series ?? "")
            case .volume:
                let av = a.volume ?? (asc ? .infinity : -.infinity)
                let bv = b.volume ?? (asc ? .infinity : -.infinity)
                return asc ? av < bv : av > bv
            }
        }
    }
}
