// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// Multi-line editable text editor for memo field with click-to-edit UI.
/// - Read-only: plain Text (multi-line preserved, `<複数値>` / `—` placeholders), hover shows light border.
/// - Click → switches to TextEditor with auto-focus.
/// - Focus out → commit + return to read-only.
/// - Esc → cancel (revert) + return to read-only.
/// - Enter inserts newline (does not commit).
struct EditableTextEditor: View {
    let label: LocalizedStringKey
    let state: MixedValueState<String>
    let onCommit: (String) -> Void
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Identifies which DetailField this editor represents.
    var fieldID: DetailField? = nil
    /// Set by parent to trigger startEditing() on the matching field.
    var requestedField: DetailField? = nil
    /// requestedField の bump counter (SwiftUI coalesce 回避用)。
    var requestedFieldNonce: Int = 0
    /// 親 (DetailPaneView) の currentEditingField への双方向 binding。
    /// 自身が isEditing になったら fieldID を書き込み、終了したら nil に戻す。
    @Binding var currentEditingField: DetailField?

    @State private var text: String = ""
    @State private var isEditing: Bool = false
    @State private var isHovering: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if isEditing {
                editingEditor
            } else {
                readOnlyText
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

    @ViewBuilder
    private var readOnlyText: some View {
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
                if shouldShowClearAction {
                    Button("消去", role: .destructive) {
                        onCommit("")  // explicit clear, bypasses no-op check
                    }
                }
            }
    }

    @ViewBuilder
    private var editingEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .background(.background)
                .frame(minHeight: 80)  // ~4 lines at default body text size
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    onFocusChange?(focused)
                    if !focused { commit() }
                }
                .task {
                    // First appearance after switching to edit mode: auto-focus
                    isFocused = true
                }
                .onKeyPress(.escape) {
                    cancelEditing()
                    return .handled
                }
                .onDisappear {
                    // View teardown (e.g., parent .id() change for selection switch): commit before destroy.
                    // Invariant: when commit() / cancelEditing() runs synchronously before teardown,
                    // isEditing is already false here, so we correctly skip the duplicate write.
                    if isEditing && !state.isNoOpCommit(text) {
                        onCommit(text)
                    }
                }
            if showPlaceholderInEdit {
                Text("<複数値>")
                    .foregroundStyle(.secondary.opacity(0.5))
                    .padding(EdgeInsets(top: 8, leading: 5, bottom: 8, trailing: 5))
                    .allowsHitTesting(false)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
    }

    private var displayText: String {
        switch state {
        case .unanimous(let v): return v.isEmpty ? "—" : v
        case .mixed:            return "<複数値>"
        }
    }

    private var displayColor: Color {
        switch state {
        case .unanimous(let v): return v.isEmpty ? Color.secondary.opacity(0.5) : .primary
        case .mixed:            return Color.secondary.opacity(0.5)
        }
    }

    private var showPlaceholderInEdit: Bool {
        if case .mixed = state, text.isEmpty { return true }
        return false
    }

    private func startEditing() {
        text = state.editorText
        isEditing = true
    }

    private func commit() {
        // Guard against re-entrant commits after cancelEditing() — see EditableTextField.commit().
        guard isEditing else { return }
        let isNoOp = state.isNoOpCommit(text)
        if !isNoOp {
            // Defer to next runloop. If commit fires synchronously during a mouse-down
            // event (focus loss when clicking another book), the resulting refreshDisplayedBooks
            // chain re-renders the grid mid-click and prevents the subsequent mouse-up tap
            // gesture from registering correctly. Deferring lets click events complete first.
            let pendingText = text
            Task { @MainActor in
                onCommit(pendingText)
            }
        }
        isEditing = false
        isHovering = false  // hover state is stale by the time we return to read-only
    }

    private var shouldShowClearAction: Bool {
        switch state {
        case .unanimous(let v): return !v.isEmpty
        case .mixed: return true
        }
    }

    private func cancelEditing() {
        text = state.editorText
        isEditing = false
        isHovering = false  // hover state is stale by the time we return to read-only
    }
}
