// SPDX-License-Identifier: MIT
import SwiftUI
import LibraryStore

/// Filter popover の未読/既読行。3 状態 segmented picker。
struct UnseenFilterRow: View {
    @Binding var unseen: FilterState.UnseenMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("既読状態").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $unseen) {
                Text("全件").tag(FilterState.UnseenMode?.none)
                Text("未読のみ").tag(Optional(FilterState.UnseenMode.unreadOnly))
                Text("既読のみ").tag(Optional(FilterState.UnseenMode.readOnly))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
