// SPDX-License-Identifier: MIT
import SwiftUI
import LibraryStore

/// Filter popover の bookType 行。0..5 の 6 種を 2 列の chip で表示し、
/// クリックで Set<Int> に追加・削除する。
struct BookTypeFilterRow: View {
    @Binding var bookTypes: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("種類").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 4) {
                ForEach(0..<6) { type in
                    chip(for: type)
                }
            }
        }
    }

    /// borderedProminent (selected) と bordered (unselected) を切替えて
    /// 視認性を上げる。@ViewBuilder で if/else 分岐を許可。
    @ViewBuilder
    private func chip(for type: Int) -> some View {
        let isSelected = bookTypes.contains(type)
        let action = {
            if isSelected { bookTypes.remove(type) } else { bookTypes.insert(type) }
        }
        let content = HStack(spacing: 4) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.hierarchical)
            Text(label(type))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if isSelected {
            Button(action: action) { content }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
        } else {
            Button(action: action) { content }
                .buttonStyle(.bordered)
                .tint(.secondary)
        }
    }

    private func label(_ type: Int) -> String {
        switch type {
        case 0: return String(localized: "厚い本")
        case 1: return String(localized: "薄い本")
        case 2: return String(localized: "本の一部")
        case 3: return String(localized: "画像セット")
        case 4: return String(localized: "テキスト")
        case 5: return String(localized: "ムービー")
        default: return "?"
        }
    }
}
