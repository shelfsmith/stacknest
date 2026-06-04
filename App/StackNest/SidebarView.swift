// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore
import StackroomFormat

struct SidebarView: View {
    @Bindable var appState: AppState
    @State private var pendingDeleteShelf: PlaylistRow?
    @State private var renamingShelfID: Int64?
    @State private var renameDraft: String = ""
    @FocusState private var renameFieldFocused: Bool
    @State private var showingNewSmartEditor = false
    @State private var editingSmartShelf: PlaylistRow?
    @State private var showingRecentDaysEditor = false

    var body: some View {
        List(selection: selectionBinding) {
            Section("ビルトイン") {
                builtInRow(title: "ライブラリ", systemImage: "books.vertical.fill",
                           tag: .library, count: appState.database == nil ? nil : appState.libraryBookCount)
                favoritesRow()
                builtInRow(title: "最近の項目", systemImage: "clock.fill",
                           tag: .recent, count: appState.database == nil ? nil : appState.recentBookCount)
                    .contextMenu {
                        Button("日数を編集…") { showingRecentDaysEditor = true }
                    }
            }
            Section("シェルフ") {
                ForEach(appState.shelves, id: \.id) { shelf in
                    shelfRow(shelf)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("新規シェルフ") { createNewShelf() }
                    Button("新規スマートシェルフ…") { showingNewSmartEditor = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(8)
                Spacer()
            }
            .background(.bar)
        }
        .alert(item: $pendingDeleteShelf) { shelf in
            Alert(
                title: Text("シェルフ \"\(shelf.title)\" を削除しますか？"),
                message: Text("シェルフを削除します。中の書籍はライブラリには残ります。"),
                primaryButton: .destructive(Text("削除")) {
                    appState.deleteShelf(id: shelf.id)
                },
                secondaryButton: .cancel(Text("キャンセル"))
            )
        }
        .sheet(isPresented: $showingNewSmartEditor) {
            if let settings = appState.librarySettings {
                SmartShelfEditorSheet(settings: settings) { name, conditions in
                    if let id = appState.createSmartShelf(name: name, conditions: conditions) {
                        appState.switchTo(.smartShelf(id: id, name: name))
                    }
                }
            }
        }
        .sheet(item: $editingSmartShelf) { shelf in
            if let settings = appState.librarySettings {
                SmartShelfEditorSheet(
                    settings: settings,
                    initialName: shelf.title,
                    initialConditions: appState.fetchSmartShelfConditions(id: shelf.id)
                        ?? SmartShelfConditions(match: .all, rules: [])
                ) { name, conditions in
                    appState.updateSmartShelf(id: shelf.id, name: name, conditions: conditions)
                }
            }
        }
        .sheet(isPresented: $showingRecentDaysEditor) {
            RecentDaysEditorSheet(initialDays: appState.librarySettings?.recentDays ?? 14) { days in
                appState.setRecentDays(days)
            }
        }
    }

    @ViewBuilder
    private func builtInRow(title: LocalizedStringKey, systemImage: String, tag: SidebarItem, count: Int?) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if let count = count {
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .tag(tag)
    }

    @ViewBuilder
    private func favoritesRow() -> some View {
        HStack {
            Label("お気に入り", systemImage: "heart.fill")
            Spacer()
            Text("\(favoritesCount)").foregroundStyle(.secondary).monospacedDigit()
        }
        .tag(SidebarItem.favorites)
        .dropDestination(for: String.self) { droppedStrings, _ in
            guard let favID = appState.favoritesShelfID else { return false }
            // FX3: grid-multi は comma-joined ("1,2,3")、list-multi は複数の単体文字列。
            // 受信した各文字列を "," で split してから Int 化することで両方を統一処理する。
            let ids = droppedStrings.flatMap { $0.split(separator: ",") }.compactMap { Int($0) }
            guard !ids.isEmpty else { return false }
            appState.addBooksToShelf(favID, books: ids)
            return true
        }
    }

    @ViewBuilder
    private func shelfRow(_ shelf: PlaylistRow) -> some View {
        // @Observable dependency reads: shelf 内容や本データが変われば badge を再評価する。
        // shelvesContentVersion = 条件編集/本追加・除外、booksDataVersion = 本編集/追加/削除。
        let _ = appState.shelvesContentVersion
        let _ = appState.booksDataVersion
        let icon = shelf.isSmart ? "line.3.horizontal.decrease.circle" : "square.stack.fill"
        let count = shelf.isSmart
            ? appState.smartShelfBookCount(id: shelf.id)
            : ((try? appState.database?.fetchPlaylistBookCount(playlistID: shelf.id)) ?? 0)
        let tag: SidebarItem = shelf.isSmart
            ? .smartShelf(id: shelf.id, name: shelf.title)
            : .shelf(id: shelf.id, name: shelf.title, kind: shelf.kind == "user" ? .user : .imported)
        HStack {
            if renamingShelfID == shelf.id {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFieldFocused)
                    .onSubmit {
                        commitRename(shelfID: shelf.id)
                    }
                    .onExitCommand {
                        renamingShelfID = nil  // Escape cancels without saving
                    }
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused && renamingShelfID == shelf.id {
                            commitRename(shelfID: shelf.id)
                        }
                    }
            } else {
                Label(shelf.title, systemImage: icon)
            }
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
        .tag(tag)
        .contextMenu {
            if shelf.isSmart {
                Button("条件を編集…") { editingSmartShelf = shelf }
            }
            Button("リネーム") {
                renameDraft = shelf.title
                renamingShelfID = shelf.id
                DispatchQueue.main.async {
                    renameFieldFocused = true
                }
            }
            Button("削除…") {
                pendingDeleteShelf = shelf
            }
        }
        .modifier(ConditionalDrop(enabled: !shelf.isSmart, shelfID: shelf.id, appState: appState))
    }

    private var favoritesCount: Int {
        appState.favoritesBookIDs.count
    }

    private func commitRename(shelfID: Int64) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            appState.renameShelf(id: shelfID, name: trimmed)
        }
        renamingShelfID = nil
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { appState.selectedSidebarItem },
            set: { newValue in
                if let item = newValue {
                    appState.switchTo(item)
                }
            }
        )
    }

    private func createNewShelf() {
        if let id = appState.createShelf(name: "新規シェルフ") {
            renameDraft = "新規シェルフ"
            renamingShelfID = id
            // Focus textfield after a tick so SwiftUI has rendered it
            DispatchQueue.main.async {
                renameFieldFocused = true
            }
        }
    }
}

/// 手動シェルフのみ drag-drop を受け付ける（スマートシェルフは動的なので無効）。
private struct ConditionalDrop: ViewModifier {
    let enabled: Bool
    let shelfID: Int64
    let appState: AppState
    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { dropped, _ in
                // FX3: grid-multi は comma-joined ("1,2,3")、list-multi は複数の単体文字列。
                // 受信した各文字列を "," で split してから Int 化することで両方を統一処理する。
                let ids = dropped.flatMap { $0.split(separator: ",") }.compactMap { Int($0) }
                guard !ids.isEmpty else { return false }
                appState.addBooksToShelf(shelfID, books: ids)
                return true
            }
        } else {
            content
        }
    }
}
