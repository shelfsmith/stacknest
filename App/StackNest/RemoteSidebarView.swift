// SPDX-License-Identifier: MIT
import AppCore
import LibraryServerAPI
import SwiftUI

/// Phase 4.2b-1b-2b Task 6: リモートライブラリの read-only サイドバー。
/// ローカルの SidebarView と異なり、棚の作成/改名/削除/ドラッグは行わずナビゲーションのみ。
struct RemoteSidebarView: View {
    @Bindable var state: RemoteLibraryState

    /// お気に入り棚（kind == "favorites"）が存在する場合のみ「お気に入り」を表示するための解決。
    private var favoritesShelf: ShelfDTO? {
        state.shelves.first { $0.kind == "favorites" }
    }

    /// ユーザー定義棚（スマートでなく、お気に入りでもない）。
    private var userShelves: [ShelfDTO] {
        state.shelves.filter { !$0.isSmart && $0.kind != "favorites" }
    }

    /// スマート棚。
    private var smartShelves: [ShelfDTO] {
        state.shelves.filter { $0.isSmart }
    }

    /// List(selection:) 用の binding。set 時に state.setSidebar(...) を呼ぶ。
    private var selectionBinding: Binding<RemoteLibraryState.RemoteSidebarSelection?> {
        Binding(
            get: { state.sidebarSelection },
            set: { if let s = $0 { state.setSidebar(s) } }
        )
    }

    var body: some View {
        List(selection: selectionBinding) {
            Label("ライブラリ", systemImage: "books.vertical.fill")
                .tag(RemoteLibraryState.RemoteSidebarSelection.library)

            if let fav = favoritesShelf {
                Label("お気に入り", systemImage: "star.fill")
                    .tag(RemoteLibraryState.RemoteSidebarSelection.favorites(fav.id))
            }

            Label("最近の項目", systemImage: "clock")
                .tag(RemoteLibraryState.RemoteSidebarSelection.recent)

            if !userShelves.isEmpty {
                Section("シェルフ") {
                    ForEach(userShelves, id: \.id) { shelf in
                        Label(shelf.title, systemImage: "books.vertical")
                            .tag(RemoteLibraryState.RemoteSidebarSelection.shelf(shelf.id))
                    }
                }
            }

            if !smartShelves.isEmpty {
                Section("スマートシェルフ") {
                    ForEach(smartShelves, id: \.id) { shelf in
                        Label(shelf.title, systemImage: "gearshape")
                            .tag(RemoteLibraryState.RemoteSidebarSelection.smartShelf(shelf.id))
                    }
                }
            }
        }
        .task { await state.loadShelves() }
    }
}
