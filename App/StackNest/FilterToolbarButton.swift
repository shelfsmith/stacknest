// SPDX-License-Identifier: MIT
import SwiftUI
import LibraryStore

/// Toolbar に置く Filter ボタン。active な filter 件数を右上にバッジ表示し、
/// クリックで FilterPopoverView を popover として開く。
struct FilterToolbarButton: View {
    @Binding var filter: FilterState
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: filter.isEmpty
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                if !filter.isEmpty {
                    Text("\(filter.activeCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 4)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .offset(x: 4, y: -4)
                }
            }
        }
        .help(filter.isEmpty ? "フィルタ" : "フィルタ (\(filter.activeCount) 個 active)")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            FilterPopoverView(filter: $filter)
                .frame(width: 320)
        }
    }
}
