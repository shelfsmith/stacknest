// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import LibraryServerAPI
import RemoteClient
import SwiftUI

/// Phase 4.2b-1: リモートライブラリの閲覧 UI（解錠フォーム / 一覧 / グリッド / ページャ）。
struct RemoteLibraryView: View {
    @Bindable var state: RemoteLibraryState

    /// D1: 一覧/グリッドに focus を与えて .onKeyPress(.return) を確実に発火させる。
    @FocusState private var listFocused: Bool

    var body: some View {
        Group {
            if state.locked && state.libraryToken == nil {
                unlockForm
            } else {
                browseView
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(state.libraryName)
    }

    // MARK: - Unlock

    @State private var password = ""

    private var unlockForm: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("「\(state.libraryName)」は保護されています")
                .font(.headline)
            SecureField("パスワード", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { Task { await state.unlock(password: password) } }
            Button("解錠") { Task { await state.unlock(password: password) } }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            if let err = state.errorText {
                Text(err).foregroundStyle(.red).font(.caption)
            }
        }
        .padding(40)
    }

    // MARK: - Browse

    private var browseView: some View {
        VStack(spacing: 0) {
            toolbar
            if let err = state.errorText {
                banner(err)
            }
            Divider()
            if state.isGrid {
                gridView
            } else {
                listView
            }
            Divider()
            pager
        }
        .task { await state.load() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("検索", text: $state.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .onSubmit {
                    state.page = 1
                    Task { await state.load() }
                }

            Picker("並び替え", selection: $state.sortKey) {
                Text("タイトル").tag("title")
                Text("シリーズ").tag("series")
                Text("追加日").tag("dateAdded")
                Text("最終閲覧").tag("lastRead")
            }
            .frame(width: 150)
            .onChange(of: state.sortKey) { _, _ in
                state.page = 1
                Task { await state.load() }
            }

            Button {
                state.ascending.toggle()
                state.page = 1
                Task { await state.load() }
            } label: {
                Image(systemName: state.ascending ? "arrow.up" : "arrow.down")
            }
            .help(state.ascending ? "昇順" : "降順")

            Spacer()

            Picker("", selection: $state.isGrid) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 90)
        }
        .padding(8)
    }

    private func banner(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.red.opacity(0.1))
    }

    // MARK: - List mode

    private var listView: some View {
        List(state.books, id: \.id, selection: $state.selection) { book in
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.body)
                let sub = [book.author, book.series].compactMap { $0 }.joined(separator: " / ")
                if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { state.openViewer(book: book) }
            .tag(book.id)
        }
        // D1: List 自体を focusable にして Return を捕捉する。検索フィールドに focus が
        // ある間は onSubmit（検索）が優先されるため、競合しない。
        .focusable()
        .focused($listFocused)
        .onKeyPress(.return) { openSelected() }
        .task { listFocused = true }
    }

    /// D1: 選択中の本を開く。一覧/グリッド共通。
    private func openSelected() -> KeyPress.Result {
        if let id = state.selection, let book = state.books.first(where: { $0.id == id }) {
            state.openViewer(book: book)
            return .handled
        }
        return .ignored
    }

    // MARK: - Grid mode

    private let gridColumns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)]

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(state.books, id: \.id) { book in
                    RemoteBookCell(book: book, state: state, selected: state.selection == book.id)
                        .onTapGesture(count: 2) { state.openViewer(book: book) }
                        .onTapGesture { state.selection = book.id }
                }
            }
            .padding(16)
        }
        // D1: グリッドでも Return で選択中の本を開く。
        .focusable()
        .focused($listFocused)
        .onKeyPress(.return) { openSelected() }
        .task { listFocused = true }
    }

    // MARK: - Pager

    private var pager: some View {
        HStack {
            Button("前") {
                if state.page > 1 {
                    state.page -= 1
                    Task { await state.load() }
                }
            }
            .disabled(state.page <= 1)

            Text("\(state.page) / \(state.pageCountTotalPages) ページ")
                .font(.caption)
                .monospacedDigit()

            Button("次") {
                if state.page < state.pageCountTotalPages {
                    state.page += 1
                    Task { await state.load() }
                }
            }
            .disabled(state.page >= state.pageCountTotalPages)

            Spacer()
            Text("全 \(state.total) 件").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

// MARK: - Grid cell

/// グリッドセル。可視時に .task で表紙を遅延ロードする（LazyVGrid なので可視セルのみ発火）。
private struct RemoteBookCell: View {
    let book: BookListItemDTO
    let state: RemoteLibraryState
    let selected: Bool

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 180)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .task(id: book.id) {
            if book.hasCover {
                if let data = await state.cover(bookID: book.id) {
                    image = NSImage(data: data)
                }
            }
        }
    }
}
