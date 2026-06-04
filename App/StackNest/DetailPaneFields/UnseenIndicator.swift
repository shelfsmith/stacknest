// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// Stackroom-style unread indicator. Replaces the macOS checkbox Toggle for `unseen`.
/// - `.unanimous(true)` (all unread) → green filled circle ●
/// - `.unanimous(false)` (all read) → empty circle ○
/// - `.mixed` (some read, some unread) → half-filled green circle ◐
///
/// Click semantics:
/// - `.unanimous(true)` click → mark all read (commit false)
/// - `.unanimous(false)` click → mark all unread (commit true)
/// - `.mixed` click → unify all to unread (commit true) — "user wants to re-read" intent
struct UnseenIndicator: View {
    let state: MixedValueState<Bool>
    let onCommit: (Bool) -> Void

    var body: some View {
        Button {
            switch state {
            case .unanimous(let v): onCommit(!v)
            case .mixed: onCommit(true)
            }
        } label: {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
                .font(.title3)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltipText)
        .accessibilityLabel(Text("未読インジケータ"))
        .accessibilityValue(accessibilityValueText)
        .accessibilityAddTraits(state == .unanimous(true) ? [.isSelected] : [])
    }

    private var symbolName: String {
        switch state {
        case .unanimous(true):  return "circle.fill"
        case .unanimous(false): return "circle"
        case .mixed:            return "circle.lefthalf.fill"
        }
    }

    private var symbolColor: Color {
        switch state {
        case .unanimous(true):  return .green
        case .unanimous(false): return .secondary
        case .mixed:            return .green.opacity(0.85)
        }
    }

    private var tooltipText: Text {
        switch state {
        case .unanimous(true):  return Text("既読にする")
        case .unanimous(false): return Text("未読にする")
        case .mixed:            return Text("未読/既読が混在（クリックで全件未読化）")
        }
    }

    private var accessibilityValueText: Text {
        switch state {
        case .unanimous(true):  return Text("未読")
        case .unanimous(false): return Text("既読")
        case .mixed:            return Text("一部未読")
        }
    }
}
