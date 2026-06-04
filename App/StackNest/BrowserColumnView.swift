// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore

/// Browser pane の 1 列を表す View。
/// Header (Menu dropdown で field 切替) + 値 List。
/// `task(id: refreshTrigger)` で関連 state が変わるたびに DB から distinctValues を再 fetch。
///
/// Phase 2.4d R1 改修:
/// - 「すべて」/値行を List(selection:) ではなく Button + onTapGesture で実装
///   (List の selection binding が「nil tag を選択解除」と区別できなかったため、
///   「すべて」click で filter 解除されない問題を回避)
/// - 「(なし)」field option 削除 (UX、Stackroom 仕様準拠)
/// - 他列で使用中の field は menu で disabled (重複設定回避)
/// - displayLabel 削除 (生 raw 値で表示、bookType/rating の文字置換は filter 機能側で扱う)
/// - 行間 separator 非表示、ヘッダ字を大きめ・各行字を小さめに
struct BrowserColumnView: View {
    let columnIndex: Int
    @Bindable var appState: AppState
    @Bindable var settings: LibrarySettings
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
        .task(id: refreshTrigger) { await loadValues() }
    }

    // MARK: - Arrow key navigation

    /// 現在選択されているインデックス。nil 選択（「すべて」）= -1 として扱う。
    private var currentSelectionIndex: Int {
        guard let sel = settings.browserPaneState.selections[columnIndex] else { return -1 }
        return values.firstIndex(of: sel) ?? -1
    }

    /// delta 分だけ選択を移動する。
    /// index -1 は「すべて」行を表す。0...values.count-1 が値行。
    private func moveSelection(by delta: Int) {
        let currentIdx = currentSelectionIndex
        let newIdx = max(-1, min(values.count - 1, currentIdx + delta))
        guard newIdx != currentIdx else { return }
        if newIdx == -1 {
            settings.browserPaneState.setSelection(nil, at: columnIndex)
        } else {
            settings.browserPaneState.setSelection(values[newIdx], at: columnIndex)
        }
    }

    @ViewBuilder
    private var headerMenu: some View {
        Menu {
            ForEach(BrowserPaneState.BrowseField.allCases, id: \.self) { f in
                Button {
                    settings.browserPaneState.setField(f, at: columnIndex)
                } label: {
                    Text(settings.browseLabel(for: f))
                }
                .disabled(isFieldUsedInOtherColumn(f))
            }
        } label: {
            HStack {
                Text(settings.browserPaneState.fields[columnIndex].map { settings.browseLabel(for: $0) } ?? "")
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
                isSelected: settings.browserPaneState.selections[columnIndex] == nil
            ) {
                isFocused = true
                settings.browserPaneState.setSelection(nil, at: columnIndex)
            }

            ForEach(values, id: \.self) { v in
                row(
                    label: v,
                    isSelected: settings.browserPaneState.selections[columnIndex] == v
                ) {
                    isFocused = true
                    settings.browserPaneState.setSelection(v, at: columnIndex)
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
        for (idx, f) in settings.browserPaneState.fields.enumerated() where idx != columnIndex {
            if f == field { return true }
        }
        return false
    }

    /// values の再 fetch trigger。field/上位列 selection/global filter/search/scope が変わるたび。
    /// booksDataVersion を含めることで、本の追加・削除時も即時リフレッシュされる。
    private var refreshTrigger: String {
        let state = settings.browserPaneState
        let upperSelections = state.selections.prefix(columnIndex).map { $0 ?? "" }.joined(separator: "|")
        let field = state.fields[columnIndex]?.sqlColumn ?? ""
        let filterEncoded = (try? JSONEncoder().encode(settings.filterState))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return "\(field):\(upperSelections):\(appState.searchQuery):\(filterEncoded):\(String(describing: appState.selectedSidebarItem)):\(appState.booksDataVersion)"
    }

    private func loadValues() async {
        guard let db = appState.database,
              let item = appState.selectedSidebarItem,
              let field = settings.browserPaneState.fields[columnIndex] else {
            values = []
            return
        }
        let scope: SidebarScope
        switch item {
        case .library:
            scope = .library
        case .favorites:
            guard let favID = appState.favoritesShelfID else { values = []; return }
            scope = .favorites(playlistID: favID)
        case .recent:
            scope = .recent(days: settings.recentDays)
        case .shelf(let id, _, _):
            scope = .shelf(playlistID: id)
        case .smartShelf(let id, _):
            scope = .smartShelf(playlistID: id)
        }
        let upperConstraints: [(String, String)] = zip(
            settings.browserPaneState.fields.prefix(columnIndex),
            settings.browserPaneState.selections.prefix(columnIndex)
        ).compactMap { (f, s) in
            guard let f = f, let s = s else { return nil }
            return (f.sqlColumn, s)
        }
        do {
            values = try db.distinctValues(
                forColumn: field.sqlColumn,
                query: appState.searchQuery,
                sidebarScope: scope,
                filter: settings.filterState,
                browserConstraints: upperConstraints
            )
        } catch {
            appState.error = .unexpected(error)
            values = []
        }
    }
}
