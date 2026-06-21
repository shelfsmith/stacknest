// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

/// 本 1 件のメタ変更（old → new）が、与えられたソート状態の下で
/// 並び順に影響し得るかを判定する純関数。
///
/// true のときだけ全再ソート（refreshSortedDisplayedBooks）が必要。false なら
/// 並び順は不変なので、呼び出し側は行内容の in-place 更新で済ませてよい。
/// 比較はキー値の不一致だけを見る保守的判定（同値なら順序不変が保証される）。
/// `column` のスイッチは default を置かず BookColumn 全列を網羅する
/// （列追加時にコンパイルエラーで気付けるようにするため）。
public func sortOrderAffected(
    old: BookRow, new: BookRow, sortMode: SortMode, columnSort: ColumnSort
) -> Bool {
    switch sortMode {
    case .seriesVolumeAsc, .seriesVolumeDesc:
        return old.series != new.series || old.volume != new.volume
    case .column:
        switch columnSort.column {
        case .title:     return old.title != new.title
        case .author:    return old.author != new.author
        case .genre:     return old.genre != new.genre
        case .neta:      return old.neta != new.neta
        case .keywordA:  return old.keywordA != new.keywordA
        case .keywordB:  return old.keywordB != new.keywordB
        case .keywordC:  return old.keywordC != new.keywordC
        case .memo:      return old.memo != new.memo
        // 4.2c-4: .series 列は「シリーズ名 → 巻数」の2段ソート(sortedByColumn(.series))に
        // 変わったため、series 同値でも volume 変更で並び順が変わり得る。両方を見る
        // （.seriesVolumeAsc/Desc と同じ保守的判定）。
        case .series:    return old.series != new.series || old.volume != new.volume
        case .rating:    return old.rating != new.rating
        case .bookType:  return old.bookType != new.bookType
        case .unseen:    return old.unseen != new.unseen
        case .dateAdded: return old.dateAdded != new.dateAdded
        case .playDate:  return old.playDate != new.playDate
        case .volume:    return old.volume != new.volume
        }
    }
}
