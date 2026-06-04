// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// Grid view 表示時のみ出現する小型 sub-toolbar。
/// 右側に grid item size slider を配置。Browser/Stamp pane の下、Grid 本体の上に位置する。
struct GridSubToolbar: View {
    @Bindable var settings: LibrarySettings

    var body: some View {
        HStack {
            Spacer()
            Image(systemName: "square.grid.3x3")
                .font(.body)
                .foregroundStyle(.secondary)
            Slider(value: $settings.gridItemSize, in: 100...300)
                .frame(width: 160)
            Image(systemName: "square.grid.2x2")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 28)
    }
}
