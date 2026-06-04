// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore

/// Grid view 背景の右クリックで表示する sort menu。
/// 12 個の BookColumn を表示し、active field には方向 indicator (chevron.up / chevron.down) を付ける。
/// 同じ field を再選択すると ascending を flip、異なる field を選択すると新 field を asc で適用する。
/// 「シリーズ → 巻数」複合ソートは単一カラムによらない複合ソートとして末尾に表示する。
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
                // 🔧 Fix D: Use localizedTitleString (plain String) to avoid LocalizedStringKey
                // interpolation that leaks "Localizable Strings(...)" description text.
                if isActive {
                    Text(verbatim: "\(col.localizedTitleString) \(settings.listViewSort.ascending ? "↑" : "↓")")
                } else {
                    Text(col.localizedTitleString)
                }
            }
        }

        // --- 複合ソート ---
        Divider()
        Button {
            // Toggle: 別 mode → .seriesVolumeAsc、Asc なら Desc、Desc なら Asc
            switch settings.sortMode {
            case .seriesVolumeAsc:
                settings.sortMode = .seriesVolumeDesc
            case .seriesVolumeDesc:
                settings.sortMode = .seriesVolumeAsc
            default:
                settings.sortMode = .seriesVolumeAsc
            }
            onChange()
        } label: {
            // macOS Menu items は Label の systemImage を表示しないため Unicode 矢印で代替する。
            switch settings.sortMode {
            case .seriesVolumeAsc:
                Text("シリーズ → 巻数 ↑")
            case .seriesVolumeDesc:
                Text("シリーズ → 巻数 ↓")
            default:
                Text("シリーズ → 巻数")
            }
        }
    }
}
