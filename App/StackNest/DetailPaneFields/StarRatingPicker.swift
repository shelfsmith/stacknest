// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// 5-star rating picker. Click on the Nth star sets rating = N.
/// Click on the currently-set Nth star again sets rating = 0 (toggle off).
/// MixedValueState: `.mixed` renders all stars greyed-out; clicking sets value normally.
struct StarRatingPicker: View {
    let state: MixedValueState<Int>
    let onCommit: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { n in
                Button {
                    let current: Int = {
                        if case .unanimous(let v) = state { return v }
                        return 0
                    }()
                    let newValue = (current == n) ? 0 : n
                    onCommit(newValue)
                } label: {
                    Image(systemName: starSymbol(for: n))
                        .foregroundStyle(starColor(for: n))
                        .font(.title3)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tooltip(for: n))
                .accessibilityLabel(Text("\(n) 段階のレート"))
                .accessibilityValue(accessibilityValueText)
                .accessibilityAddTraits(isFilled(n) ? [.isSelected] : [])
            }
        }
    }

    private func starSymbol(for n: Int) -> String {
        switch state {
        case .unanimous(let v):
            return n <= v ? "star.fill" : "star"
        case .mixed:
            return "star"
        }
    }

    private func starColor(for n: Int) -> Color {
        switch state {
        case .unanimous(let v):
            return n <= v ? .yellow : Color.secondary
        case .mixed:
            // .tertiary is ShapeStyle, not Color — use a muted secondary tone instead
            return Color.secondary.opacity(0.4)
        }
    }

    private func isFilled(_ n: Int) -> Bool {
        if case .unanimous(let v) = state { return n <= v }
        return false
    }

    private func tooltip(for n: Int) -> String {
        let current: Int = {
            if case .unanimous(let v) = state { return v }
            return 0
        }()
        if current == n {
            return String(localized: "レートを 0 にする")
        }
        return String(localized: "レートを \(n) にする")
    }

    private var accessibilityValueText: Text {
        switch state {
        case .unanimous(let v):
            return Text("現在 \(v) 段階")
        case .mixed:
            return Text("複数値")
        }
    }
}
