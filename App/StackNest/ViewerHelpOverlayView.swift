// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

struct ViewerHelpOverlayView: View {
    /// 現在の割当から生成（再割当に追従）。HelpView も同じ rows を参照する。
    static var rows: [(action: String, keys: String)] {
        ViewerHelpRows.make(from: ViewerKeyBindings.load())
    }
    var isVisible: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("キー操作").font(.system(size: 13, weight: .bold))
            ForEach(Self.rows, id: \.action) { row in
                HStack(spacing: 12) {
                    // Phase 2.6b-2 T-U1/v7: 220 → 460 に拡幅 + lineLimit(1)（結合ショートカット行の折り返し完全防止）
                    Text(row.keys).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 460, alignment: .leading)
                        .lineLimit(1)
                    Text(row.action).font(.system(size: 12))
                }
            }
        }
        .padding(18)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isVisible)
    }
}
