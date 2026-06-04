// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// 6 colored icons representing bookType, displayed inline. Click to set.
/// - 0=厚い本 (red), 1=薄い本 (orange), 2=本の一部 (yellow),
/// - 3=画像セット (green), 4=テキスト (blue), 5=ムービー (purple)
/// Selected type renders filled with accent background; others render outlined secondary.
/// `.mixed` renders all outlined.
///
/// Color assignments are provisional — original Stackroom color observation
/// is tracked as a follow-up in roadmap §6.
struct BookTypePicker: View {
    let state: MixedValueState<Int>
    let onCommit: (Int) -> Void

    /// Single source of truth for the bookType ↔ icon ↔ color ↔ label mapping.
    /// Indexed by raw bookType value (0...5).
    private struct Descriptor {
        let icon: String
        let color: Color
        let label: LocalizedStringKey
    }

    private static let descriptors: [Descriptor] = [
        .init(icon: "book.fill",           color: .red,    label: "厚い本"),
        .init(icon: "book",                color: .orange, label: "薄い本"),
        .init(icon: "doc.fill",            color: .yellow, label: "本の一部"),
        .init(icon: "photo.stack.fill",    color: .green,  label: "画像セット"),
        .init(icon: "doc.text.fill",       color: .blue,   label: "テキスト"),
        .init(icon: "play.rectangle.fill", color: .purple, label: "ムービー"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.descriptors.indices, id: \.self) { type in
                let d = Self.descriptors[type]
                Button { onCommit(type) } label: {
                    Image(systemName: d.icon)
                        .foregroundStyle(isSelected(type) ? d.color : .secondary)
                        .font(.title3)
                        .frame(width: 24, height: 24)
                        .background(isSelected(type) ? Color.accentColor.opacity(0.15) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(d.label))
                .accessibilityLabel(Text(d.label))
                .accessibilityAddTraits(isSelected(type) ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("種類"))
    }

    private func isSelected(_ type: Int) -> Bool {
        if case .unanimous(let v) = state { return v == type }
        return false
    }
}
