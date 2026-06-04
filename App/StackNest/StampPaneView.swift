// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore

/// Stamp pane: 5 列横並び (ジャンル / 関連 / キーワードA / B / C)。
/// 各列は StampColumnView。Browser pane と同じ位置 (LibraryBrowserView 上部) に配置される。
struct StampPaneView: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(StampField.allCases.enumerated()), id: \.element) { index, field in
                StampColumnView(field: field, appState: appState)
                    .frame(maxWidth: .infinity)
                if index < StampField.allCases.count - 1 {
                    Divider()
                }
            }
        }
        .frame(height: 200)
    }
}
