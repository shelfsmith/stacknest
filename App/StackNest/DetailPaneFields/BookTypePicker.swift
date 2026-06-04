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
    /// カスタムラベル解決用。nil 時は正準ラベルにフォールバック。
    var settings: LibrarySettings?
    let onCommit: (Int) -> Void

    /// Single source of truth for the bookType ↔ icon ↔ color mapping.
    /// Indexed by raw bookType value (0...5).
    private struct Descriptor {
        let icon: String
        let color: Color
    }

    private static let descriptors: [Descriptor] = [
        .init(icon: "book.fill",           color: .red),
        .init(icon: "book",                color: .orange),
        .init(icon: "doc.fill",            color: .yellow),
        .init(icon: "photo.stack.fill",    color: .green),
        .init(icon: "doc.text.fill",       color: .blue),
        .init(icon: "play.rectangle.fill", color: .purple),
    ]

    private func typeLabel(_ type: Int) -> String {
        settings?.bookTypeLabel(type) ?? BookTypeLabel.canonicalLabel(for: type)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.descriptors.indices, id: \.self) { type in
                let d = Self.descriptors[type]
                let label = typeLabel(type)
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
                .help(label)
                .accessibilityLabel(label)
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
