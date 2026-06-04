// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// Click-to-edit numeric field for `volume` (Double?).
///
/// - Read-only: shows the volume as a formatted number, or "—" when nil.
///   Multi-select with differing values shows "<複数値>".
/// - Click → switches to a numeric TextField (`.number` format).
/// - Focus out / Return → commit. Empty input commits nil (clears volume).
/// - Esc → cancel (revert to original value).
struct VolumeEditorField: View {
    let state: MixedValueState<Double?>
    var fieldID: DetailField? = nil
    var requestedField: DetailField? = nil
    /// requestedField の bump counter (SwiftUI coalesce 回避用)。
    var requestedFieldNonce: Int = 0
    /// 親 (DetailPaneView) の currentEditingField への双方向 binding。
    /// 自身が isEditing になったら fieldID を書き込み、終了したら nil に戻す。
    @Binding var currentEditingField: DetailField?
    let onCommit: (Double?) -> Void

    @State private var text: String = ""
    @State private var isEditing: Bool = false
    @State private var isHovering: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("巻数").font(.caption).foregroundStyle(.secondary)
            if isEditing {
                editingField
            } else {
                readOnlyField
            }
        }
        .onChange(of: requestedFieldNonce) { _, _ in
            if let id = fieldID, requestedField == id, !isEditing {
                startEditing()
            }
        }
        .onChange(of: isEditing) { _, editing in
            guard let id = fieldID else { return }
            if editing {
                currentEditingField = id
            } else if currentEditingField == id {
                currentEditingField = nil
            }
        }
    }

    // MARK: - Read-only view

    @ViewBuilder
    private var readOnlyField: some View {
        Text(displayText)
            .foregroundStyle(displayColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isHovering ? Color.secondary.opacity(0.08) : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isHovering ? Color.secondary.opacity(0.4) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in isHovering = hovering }
            .onTapGesture { startEditing() }
            .contextMenu {
                if state.shouldShowClearAction {
                    Button("消去", role: .destructive) {
                        onCommit(nil)
                    }
                }
            }
    }

    // MARK: - Editing view

    @ViewBuilder
    private var editingField: some View {
        TextField("", text: $text, prompt: prompt)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .task {
                isFocused = true
            }
            .onKeyPress(.escape) {
                cancelEditing()
                return .handled
            }
            .onDisappear {
                if isEditing {
                    let parsed = parseText(text)
                    // commit only when value actually changed
                    if !isNoOpCommit(parsed) {
                        onCommit(parsed)
                    }
                }
            }
    }

    // MARK: - Helpers

    private var displayText: String {
        switch state {
        case .unanimous(let v):
            guard let v else { return "—" }
            // Show as integer when the value is a whole number (e.g. 1.0 → "1")
            return v == v.rounded() ? String(Int(v)) : String(v)
        case .mixed:
            return "<複数値>"
        }
    }

    private var displayColor: Color {
        switch state {
        case .unanimous(let v): return v == nil ? Color.secondary.opacity(0.5) : Color.primary
        case .mixed:            return Color.secondary.opacity(0.5)
        }
    }

    private var prompt: Text? {
        if case .mixed = state { return Text("<複数値>") }
        return nil
    }

    private func startEditing() {
        switch state {
        case .unanimous(let v):
            guard let v else { text = ""; isEditing = true; return }
            text = v == v.rounded() ? String(Int(v)) : String(v)
        case .mixed:
            text = ""
        }
        isEditing = true
    }

    /// Parse the text field content into Double? (nil = empty = clear).
    private func parseText(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

/// Returns true when committing `value` would be a no-op for this state.
    private func isNoOpCommit(_ value: Double?) -> Bool {
        switch state {
        case .unanimous(let v) where v == value: return true
        case .mixed where value == nil: return true  // user left the field empty
        default: return false
        }
    }

    private func commit() {
        guard isEditing else { return }
        let parsed = parseText(text)
        if !isNoOpCommit(parsed) {
            let pendingValue = parsed
            Task { @MainActor in
                onCommit(pendingValue)
            }
        }
        isEditing = false
        isHovering = false
    }

    private func cancelEditing() {
        isEditing = false
        isHovering = false
    }
}
