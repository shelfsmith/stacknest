// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore

/// Grid view 背景の右クリックで表示する sort menu。
/// 全 BookColumn を表示し、active field には方向 indicator (↑/↓) を付ける。
/// 同じ field を再選択すると ascending を flip、異なる field を選択すると新 field を asc で適用する。
/// 4.2c-4: 旧「シリーズ → 巻数」複合ソートは廃止。単一カラム「シリーズ」がリモート同様に
/// 同一シリーズ内を巻数順に並べる（sortedByColumn(.series)）ため複合項目は不要になった。
/// Phase 2.4c (commit `22ea96d` 系列以降)。Phase 2.5c-a Task 11 で複合ソート追加。
/// Phase 2.5c-b: smoke v1 NG 後に確認 — @Bindable settings の chevron indicator は List view 相当。
struct GridSortContextMenu: View {
    @Bindable var settings: LibrarySettings
    let onChange: () -> Void

    var body: some View {
        // --- 単一カラムソート ---
        ForEach(BookColumn.allCases, id: \.self) { col in
            Button {
                // 複合ソートモードから単一カラムに切り替える場合は .column に戻す
                settings.sortMode = .column
                if settings.listViewSort.column == col {
                    settings.listViewSort = ColumnSort(
                        column: col,
                        ascending: !settings.listViewSort.ascending
                    )
                } else {
                    settings.listViewSort = ColumnSort(column: col, ascending: true)
                }
                onChange()
            } label: {
                // 複合ソートが有効な場合は単一カラムのアクティブ表示を外す
                // macOS Menu items は Label の systemImage を表示しないため Unicode 矢印で代替する。
                let isActive = settings.sortMode == .column && settings.listViewSort.column == col
                // Use settings.label(for:) so custom field labels (genre/neta/keyword_a/keyword_b)
                // are reflected. For non-customizable columns, label(for:) returns localizedTitleString.
                if isActive {
                    Text(verbatim: "\(settings.label(for: col)) \(settings.listViewSort.ascending ? "↑" : "↓")")
                } else {
                    Text(settings.label(for: col))
                }
            }
        }
        // 旧「シリーズ → 巻数」複合ソートは廃止。単一カラム「シリーズ」が
        // リモート同様に同一シリーズ内を巻数順に並べる（sortedByColumn(.series)）。
    }
}
