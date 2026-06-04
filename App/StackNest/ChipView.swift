// SPDX-License-Identifier: MIT
import SwiftUI

/// Stamp pane で使う共通 chip スタイル。3 variants:
/// - `.clear`: 「消去」chip (列先頭固定、destructive 赤系)
/// - `.value(String)`: 既存値 chip (accent 色)
/// - `.newAdd`: 「+ 新規追加」chip (列末尾固定、緑系 + plus icon)
struct ChipView: View {
    enum Variant {
        case clear
        case value(String)
        case newAdd
    }

    let variant: Variant
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                switch variant {
                case .clear:
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                    Text("消去")
                        .font(.caption)
                case .value(let s):
                    Text(s)
                        .font(.caption)
                        .lineLimit(1)
                case .newAdd:
                    Image(systemName: "plus.circle.fill")
                        .font(.caption)
                    Text("新規追加")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
    }

    private var backgroundColor: Color {
        switch variant {
        case .clear:  return Color.red.opacity(0.7)
        case .value:  return Color.accentColor.opacity(0.15)
        case .newAdd: return Color.green.opacity(0.85)
        }
    }

    private var foregroundColor: Color {
        switch variant {
        case .clear:  return Color.white
        case .value:  return Color.primary
        case .newAdd: return Color.white
        }
    }
}
