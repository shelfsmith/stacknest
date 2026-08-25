// SPDX-License-Identifier: MIT
import SwiftUI
import LibraryStore
import AppCore

/// Toolbar に置く Filter ボタン。active な filter 件数を右上にバッジ表示し、
/// クリックで FilterPopoverView を popover として開く。
struct FilterToolbarButton: View {
    @Binding var filter: FilterState
    /// カスタムラベル解決用。nil 時は正準ラベルにフォールバック。
    var settings: LibrarySettings?
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            // G42: **`Label` にする。**ツールバーを右クリックして「アイコンとテキスト」に
            // したとき、テキストが出るのは `Label` を持つ項目だけ。ここは `ZStack` を直に
            // ラベルにしていたので、この項目だけ名前が出なかった。
            // バッジは `icon:` 側に入れたままなので**見た目は変わらない**。
            Label {
                Text("フィルタ")
            } icon: {
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
        }
        .help(filter.isEmpty ? "フィルタ" : "フィルタ (\(filter.activeCount) 個 active)")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            FilterPopoverView(filter: $filter, settings: settings)
                .frame(width: 320)
        }
    }
}
