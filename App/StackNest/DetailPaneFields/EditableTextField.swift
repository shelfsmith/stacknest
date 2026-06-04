// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// Single-line editable text field with click-to-edit UI.
/// - Read-only: plain Text (or `<複数値>` / `—` placeholders), hover shows light border.
/// - When `onJumpToFilter` is provided: displays inline chip(s) + jump button(s) instead
///   of plain text. Comma-separated multi-values render as multiple chips (Stackroom-compatible).
/// - Click / chip-click → switches to TextField with auto-focus.
/// - Focus out → commit + return to read-only.
/// - Esc → cancel (revert to source value) + return to read-only.
/// - Whitespace trimming is NOT performed by this component — callers are responsible
///   if their field requires it (Database.updateBook trims title; tag/keyword fields
///   currently persist whitespace as-is, by design).
struct EditableTextField: View {
    let label: LocalizedStringKey
    let state: MixedValueState<String>
    let onCommit: (String) -> Void
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Identifies which DetailField this editor represents.
    var fieldID: DetailField? = nil
    /// Set by parent to trigger startEditing() on the matching field.
    var requestedField: DetailField? = nil
    /// requestedField の bump counter。advanceField/retreatField が +1 する。
    /// 同じ field を連続 request しても onChange を確実に発火させるため
    /// (SwiftUI が `nil → X → nil` を coalesce する race を回避)。
    var requestedFieldNonce: Int = 0
    /// 親 (DetailPaneView) の currentEditingField への双方向 binding。
    /// 自身が isEditing になったら fieldID を書き込み、終了したら nil に戻す。
    /// TabFocusController がこの値を見て Tab を advance/retreat に dispatch する。
    @Binding var currentEditingField: DetailField?
    /// When non-nil, read-only display switches to inline chip(s) + jump button(s).
    /// The closure receives the individual tag value (comma-split) to filter by.
    var onJumpToFilter: ((String) -> Void)? = nil

    @State private var text: String = ""
    @State private var isEditing: Bool = false
    @State private var isHovering: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if isEditing {
                editingField
            } else {
                readOnlyField
            }
        }
        .onChange(of: requestedFieldNonce) { _, _ in
            // requestedFieldNonce が bump されたら request された field を読み、自分宛なら開始。
            // nonce ベースなので requestedField が同じ値の連続でも fire する。
            if let id = fieldID, requestedField == id, !isEditing {
                startEditing()
            }
        }
        .onChange(of: isEditing) { _, editing in
            // TabFocusController に「誰が今編集中か」を通知。
            // 編集開始: 自分の fieldID をセット (fieldID 未設定なら no-op = Tab navigation 対象外)
            // 編集終了: 自分が現在 owner なら nil に戻す (他 field が既に上書きしていれば触らない)
            guard let id = fieldID else { return }
            if editing {
                currentEditingField = id
            } else if currentEditingField == id {
                currentEditingField = nil
            }
        }
    }

    @ViewBuilder
    private var readOnlyField: some View {
        if let jumpHandler = onJumpToFilter, case .unanimous(let v) = state {
            // Inline chip + jump button display (Stackroom-compatible).
            // When value is empty: show "—" placeholder that starts editing on tap.
            // When value is non-empty: show chip(s) per comma-split item + per-item jump button.
            inlineChipRow(value: v, onJump: jumpHandler)
        } else {
            plainReadOnlyField
        }
    }

    /// Plain text display (no jump button): used for title, memo, and multi-select state.
    @ViewBuilder
    private var plainReadOnlyField: some View {
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

    /// Inline chip + jump button row (Stackroom-compatible read-only display).
    /// Comma-separated values render as individual chips, each with its own jump button.
    ///
    /// Button は使わず onTapGesture ベースで実装する。
    /// Button は AppKit の key-view loop に登録されるため、.focusable(false) を付けても
    /// SwiftUI / macOS バージョン依存で Tab navigation を阻害することがある。
    /// Text + onTapGesture / Image + onTapGesture は key-view loop に登録されないため
    /// Tab キー押下時に chip を跨いで TextField 間を正常に移動できる。
    @ViewBuilder
    private func inlineChipRow(value: String, onJump: @escaping (String) -> Void) -> some View {
        let tags = Self.splitTags(value)
        if tags.isEmpty {
            // Empty value: em-dash placeholder, tap to edit
            Text("—")
                .foregroundStyle(Color.secondary.opacity(0.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { startEditing() }
        } else {
            FlowLayout(spacing: 4) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        // chip text: Button → Text + onTapGesture
                        // Use body font (same as the title field read-only display) so
                        // chip text size matches the other Detail Pane text fields.
                        // Allow wrapping for long values so chip doesn't overflow the pane.
                        // Detail Pane 固定幅 240pt から jump button (~28pt) と
                        // padding (~16pt) を引いた ~196pt が上限。
                        // 余裕を持たせて 180pt を採用。
                        Text(tag)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 180, alignment: .leading)
                            .padding(.leading, 8)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture { startEditing() }

                        // jump arrow: Button → Image + onTapGesture
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { onJump(tag) }
                            .help(Text("「\(tag)」で絞り込む"))
                            .accessibilityLabel(Text("「\(tag)」で絞り込む"))
                    }
                    .background(.tertiary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .contextMenu {
                Button("消去", role: .destructive) {
                    onCommit("")
                }
            }
        }
    }

    /// Splits a comma-separated tag string into trimmed, non-empty parts.
    static func splitTags(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private var editingField: some View {
        TextField("", text: $text, prompt: prompt)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                onFocusChange?(focused)
                if !focused { commit() }
            }
            .task {
                // First appearance after switching to edit mode: auto-focus on the next runloop tick
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
    }

    private var displayText: String {
        switch state {
        case .unanimous(let v): return v.isEmpty ? "—" : v
        case .mixed:            return "<複数値>"
        }
    }

    private var displayColor: Color {
        switch state {
        case .unanimous(let v): return v.isEmpty ? Color.secondary.opacity(0.5) : Color.primary
        case .mixed:            return Color.secondary.opacity(0.5)
        }
    }

    private var prompt: Text? {
        if case .mixed = state { return Text("<複数値>") }
        return nil
    }

    private func startEditing() {
        text = state.editorText
        isEditing = true
    }

    private func commit() {
        // Guard against re-entrant commits after cancelEditing() — see comment above.
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
