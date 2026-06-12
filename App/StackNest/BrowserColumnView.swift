// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// Browser pane の 1 列を表す View。
/// Header (Menu dropdown で field 切替) + 値 List。
/// `task(id: refreshKey)` で関連 state が変わるたびに distinctValues を再 fetch。
///
/// Phase 2.4d R1 改修:
/// - 「すべて」/値行を List(selection:) ではなく Button + onTapGesture で実装
///   (List の selection binding が「nil tag を選択解除」と区別できなかったため、
///   「すべて」click で filter 解除されない問題を回避)
/// - 「(なし)」field option 削除 (UX、Stackroom 仕様準拠)
/// - 他列で使用中の field は menu で disabled (重複設定回避)
/// - displayLabel 削除 (生 raw 値で表示、bookType/rating の文字置換は filter 機能側で扱う)
/// - 行間 separator 非表示、ヘッダ字を大きめ・各行字を小さめに
///
/// Phase 4.2b-1b-2a: AppState/db 依存を排除。injected closures で backend-agnostic に。
struct BrowserColumnView: View {
    let columnIndex: Int
    @Binding var browserPaneState: BrowserPaneState
    let labelFor: (BrowserPaneState.BrowseField) -> String
    let refreshKey: String
    let facetValues: (_ columnSQL: String, _ upperConstraints: [(String, String)]) async -> [String]
    @State private var values: [String] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerMenu
            Divider()
            valueList
        }
        .focusable()
        .focused($isFocused)
        .onKeyPress(.upArrow)   { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: +1); return .handled }
        .task(id: refreshKey) { await loadValues() }
    }

    // MARK: - Arrow key navigation

    /// 現在選択されているインデックス。nil 選択（「すべて」）= -1 として扱う。
    private var currentSelectionIndex: Int {
        guard let sel = browserPaneState.selections[columnIndex] else { return -1 }
        return values.firstIndex(of: sel) ?? -1
    }

    /// delta 分だけ選択を移動する。
    /// index -1 は「すべて」行を表す。0...values.count-1 が値行。
    private func moveSelection(by delta: Int) {
        let currentIdx = currentSelectionIndex
        let newIdx = max(-1, min(values.count - 1, currentIdx + delta))
        guard newIdx != currentIdx else { return }
        if newIdx == -1 {
            browserPaneState.setSelection(nil, at: columnIndex)
        } else {
            browserPaneState.setSelection(values[newIdx], at: columnIndex)
        }
    }

    @ViewBuilder
    private var headerMenu: some View {
        Menu {
            ForEach(BrowserPaneState.BrowseField.allCases, id: \.self) { f in
                Button {
                    browserPaneState.setField(f, at: columnIndex)
                } label: {
                    Text(labelFor(f))
                }
                .disabled(isFieldUsedInOtherColumn(f))
            }
        } label: {
            HStack {
                Text(browserPaneState.fields[columnIndex].map { labelFor($0) } ?? "")
                    .font(.subheadline)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private var valueList: some View {
        List {
            // 「すべて (N 種類)」: click で当該列の selection を nil にリセット
            row(
                label: "すべて (\(values.count) 種類)",
                isSelected: browserPaneState.selections[columnIndex] == nil
            ) {
                isFocused = true
                browserPaneState.setSelection(nil, at: columnIndex)
            }

            ForEach(values, id: \.self) { v in
                row(
                    label: v,
                    isSelected: browserPaneState.selections[columnIndex] == v
                ) {
                    isFocused = true
                    browserPaneState.setSelection(v, at: columnIndex)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Text(label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .listRowSeparator(.hidden)
            .listRowBackground(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { action() }
    }

    /// columnIndex 以外の他列で同じ field が使われていれば true (重複設定の防止)。
    private func isFieldUsedInOtherColumn(_ field: BrowserPaneState.BrowseField) -> Bool {
        for (idx, f) in browserPaneState.fields.enumerated() where idx != columnIndex {
            if f == field { return true }
        }
        return false
    }

    private func loadValues() async {
        guard let field = browserPaneState.fields[columnIndex] else { values = []; return }
        let upperConstraints: [(String, String)] = zip(
            browserPaneState.fields.prefix(columnIndex),
            browserPaneState.selections.prefix(columnIndex)
        ).compactMap { (f, s) in
            guard let f = f, let s = s else { return nil }
            return (f.sqlColumn, s)
        }
        values = await facetValues(field.sqlColumn, upperConstraints)
    }
}
