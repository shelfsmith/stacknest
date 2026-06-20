// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore

/// Stamp pane: 5 列横並び (ジャンル / 関連 / キーワードA / B / C)。
/// 各列は汎用 StampColumnView。AppState 由来のクロージャを注入する（4.2c-6a）。
struct StampPaneView: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(StampField.allCases.enumerated()), id: \.element) { index, field in
                StampColumnView(
                    field: field,
                    label: appState.librarySettings?.stampLabel(for: field) ?? field.localizedTitle,
                    definitions: (appState.librarySettings?.stampDefinitions[field.dbColumn] ?? []).sorted(),
                    applyEnabled: !appState.selectedBookIDs.isEmpty,
                    onApplyValue: { appState.applyStamp(field: field, value: $0) },
                    onApplyClear: { appState.clearStamp(field: field) },
                    onAddDefinition: { appState.addStampDefinition(field: field, value: $0) },
                    onDeleteDefinition: { appState.deleteStampDefinition(field: field, value: $0) }
                )
                .frame(maxWidth: .infinity)
                if index < StampField.allCases.count - 1 {
                    Divider()
                }
            }
        }
        .frame(height: 200)
    }
}
