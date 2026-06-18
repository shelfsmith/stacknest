// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import LibraryServerAPI
import LibraryStore
import SwiftUI

/// Phase 4.2b-2 Task 5: オフライン（ダウンロード済み）ライブラリの閲覧 UI。
/// サーバ接続を一切持たず、OfflineStore + ローカルファイルのみで動作する。
/// ダウンロード済みの本を一覧し、内蔵ビューワでオフライン再生する。
struct OfflineLibraryView: View {
    @State private var books: [DownloadedBook] = []
    @State private var query = ""
    @State private var errorText: String? = nil
    /// ネイティブ List(selection:) による複数選択（⌘/Shift）。単一選択でも詳細ペインを駆動する。
    @State private var multiSelection: Set<String> = []
    /// 内蔵ビューワを 1 ウィンドウだけ保持する（RemoteLibraryState.viewerController と同方針）。
    @State private var viewer: ViewerWindowController? = nil
    /// Bug 3b: List に focus を当て、Return キーで選択中の本を開けるようにする
    /// （.searchable が focus を保持していると onKeyPress(.return) が発火しない）。
    @FocusState private var listFocused: Bool

    private let store = OfflineStore()

    var body: some View {
        // O4: ローカル/リモートとの整合のため「一覧（主・広い）＋詳細（固定240）」の 2 ペイン。
        // HSplitView はコンテンツ理想サイズで配分し maxWidth を厳守しないため、詳細の中身
        // （未選択の空状態 vs 選択時）で一覧幅（＝footer 幅）が揺れる（V4 NG）。
        // → HStack で詳細を真の固定幅にし、一覧幅を選択状態に依らず一定にする。
        NavigationStack {
            HStack(spacing: 0) {
                listColumn
                    .frame(maxWidth: .infinity)
                Divider()
                detailPane
                    .frame(width: 240)
            }
            .frame(minWidth: 760, minHeight: 480)
            .navigationTitle("オフライン")
            .searchable(text: $query, placement: .toolbar, prompt: "タイトルで検索")
        }
        .task { reload() }
        // O2: 別ウィンドウ（リモートブラウズ）で DL/削除されたら即座に反映する。
        .onReceive(NotificationCenter.default.publisher(for: .offlineStoreDidChange)) { _ in
            reload()
        }
        // ⌘⇧O 復帰: オフラインウィンドウが既に開いている場合、openWindow はフォーカスのみで
        // .task を再実行しないため、通知で reload() を発火し pendingBookID を消費する。
        .onReceive(NotificationCenter.default.publisher(for: .offlineResumeRequested)) { _ in
            reload()
        }
    }

    // MARK: - Reload

    private func reload() {
        books = store.all()
        // Phase 4.2c-2: オフライン resume 意図を 1 回だけ消費する。対象本（サーバ側 bookID 一致）が
        // DL 済みにあれば続き確認なしで開く。self-clear するため再 reload では再発火しない。
        if let id = OfflineResumeIntent.shared.pendingBookID, let book = books.first(where: { $0.detail.id == id }) {
            OfflineResumeIntent.shared.pendingBookID = nil
            openOffline(book, resumeDirect: true)
        }
    }

    /// query（タイトル一致）で絞り込んだ本。
    private var filtered: [DownloadedBook] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return books }
        return books.filter { $0.detail.title.localizedCaseInsensitiveContains(q) }
    }

    /// libraryName ごとにグルーピング（セクション表示用）。
    private var groups: [(library: String, books: [DownloadedBook])] {
        let dict = Dictionary(grouping: filtered, by: { $0.libraryName })
        return dict.keys.sorted().map { name in
            (library: name, books: dict[name]!.sorted { $0.detail.title < $1.detail.title })
        }
    }

    // MARK: - List column (main pane)

    private var listColumn: some View {
        VStack(spacing: 0) {
            // 2 件以上選択されたときだけ一括操作バーを出す（単一選択は詳細ペインで扱う）。
            if multiSelection.count >= 2 {
                selectionBar
                Divider()
            }
            if let errorText {
                banner(errorText)
                Divider()
            }
            if books.isEmpty {
                ContentUnavailableView(
                    "ダウンロード済みの本がありません",
                    systemImage: "arrow.down.circle",
                    description: Text("サーバ接続時に本をダウンロードすると、ここでオフライン閲覧できます。")
                )
            } else {
                listView
                Divider()
                // O1: footer（件数/合計サイズ）は本があるときだけ表示（空状態で出さない）。
                footer
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(multiSelection.count) 件選択").font(.callout).foregroundStyle(.secondary)
            Button("すべて選択") { selectAllVisible() }
            Button("選択解除") { clearSelection() }
            Spacer()
            Button(role: .destructive) { deleteSelected() } label: {
                Label("選択を削除", systemImage: "trash")
            }
            .disabled(multiSelection.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var listView: some View {
        // ネイティブ複数選択: Set バインディングにより ⌘/Shift クリックで複数選択できる。
        // 単一クリックは List のネイティブ選択が処理する（明示の onTapGesture は置かない）。
        List(selection: $multiSelection) {
            ForEach(groups, id: \.library) { group in
                Section(group.library) {
                    ForEach(group.books) { book in
                        row(book)
                            .tag(book.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { openOffline(book) }
                            .contextMenu {
                                Button("開く") { openOffline(book) }
                                Divider()
                                Button("削除", role: .destructive) { delete(book) }
                            }
                    }
                }
            }
        }
        .onKeyPress(.return) {
            // 単一選択のときだけ開く（複数選択時は Return を無視）。
            if multiSelection.count == 1, let book = selectedBook { openOffline(book); return .handled }
            return .ignored
        }
        // Bug 3b: List 自身に focus を当てて Return キーを受け取る（RemoteLibraryView と同方針）。
        .focusable()
        .focused($listFocused)
        .task { listFocused = true }
    }

    private func row(_ book: DownloadedBook) -> some View {
        HStack(spacing: 8) {
            thumbnail(book)
                .frame(width: 36, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.detail.title)
                    .font(.body)
                    .lineLimit(2)
                let sub = [book.detail.author, book.detail.series]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")
                if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func thumbnail(_ book: DownloadedBook) -> some View {
        if book.hasCachedCover, let img = NSImage(contentsOf: store.coverURL(for: book)) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "book").foregroundStyle(.secondary))
        }
    }

    private var footer: some View {
        HStack {
            Text("\(books.count) 件")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: store.totalSizeBytes(), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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

    // MARK: - Detail pane

    /// 詳細ペイン用: 単一選択のときのみ本を返す（複数選択時は nil）。
    private var selectedBook: DownloadedBook? {
        multiSelection.count == 1 ? books.first { multiSelection.contains($0.id) } : nil
    }

    private func selectedRows() -> [BookRow] {
        guard let book = selectedBook else { return [] }
        return [offlineBookRow(book, fileURL: store.fileURL(for: book))]
    }

    /// 共有 read-only DetailPaneView（RemoteLibraryView と同様、編集系は no-op）。
    private var detailPane: some View {
        DetailPaneView(
            books: selectedRows(),
            librarySettings: nil,
            bundleURL: URL(fileURLWithPath: "/"),
            loader: nil,
            canEdit: false,
            onApplyPatch: { _, _ in }, onApplyPatchMulti: { _, _ in },
            onSetCover: { _, _ in }, onClearCrop: { _ in }, onSetCrop: { _, _ in },
            onJump: { _, _ in }, onError: { _ in },
            coverImage: { id in await offlineCover(id) }
        )
    }

    /// detail pane の coverImage 注入用。選択中の本のキャッシュ表紙を NSImage で返す。
    private func offlineCover(_ bookID: Int) async -> NSImage? {
        guard let book = books.first(where: { $0.detail.id == bookID }), book.hasCachedCover else {
            return nil
        }
        return NSImage(contentsOf: store.coverURL(for: book))
    }

    // MARK: - Actions

    /// オフライン保存済みの本を内蔵ビューワで開く。BookContent はローカルファイル経由。
    private func openOffline(_ book: DownloadedBook, resumeDirect: Bool = false) {
        // Phase 4.2c-2: 「最後に開いた本」を記録する（オフライン・サーバ側 bookID を採用）。
        LastReadTracker.shared.record(.offline(bookID: book.detail.id, title: book.detail.title))
        // Phase 4.2c-2 (B2): 開く瞬間に OfflineStore から最新の lastPage を読む。
        // captured `book`（@State books 由来）は前回 read 後 reload 前だと古い lastPage を持つため。
        let freshLastPage = store.all().first(where: { $0.id == book.id })?.lastPage ?? book.lastPage
        let fileURL = store.fileURL(for: book)
        let row = offlineBookRow(book, fileURL: fileURL)
        let content: BookContent
        do {
            content = try BookContentFactory.make(for: row)
        } catch {
            errorText = "本を開けませんでした（オフライン非対応のファイル）"
            return
        }
        Task { @MainActor in
            let pageCount: Int
            do {
                pageCount = try await content.pageCount
            } catch {
                self.errorText = "本を開けませんでした"
                return
            }
            guard pageCount > 0 else {
                self.errorText = "本を開けませんでした（0ページ）"
                return
            }
            // ローカル DB は持たないため、見開きはグローバル既定で開き、lastPage は OfflineStore の値。
            let initialState = ResolvedViewerState(
                spreadEnabled: ViewerSettings.shared.spreadByDefault,
                coverOffset: true,
                lastPage: max(0, freshLastPage ?? 0),
                overrides: [:]
            )
            let options = ViewerOptions(
                pageDirection: row.pageDirection ?? ViewerSettings.shared.pageDirection,
                endOfBookBehavior: ViewerSettings.shared.endOfBookBehavior
            )
            let serverID = book.serverID
            let libraryUUID = book.libraryUUID
            let store = self.store
            let controller = ViewerWindowController(
                content: content,
                book: row,
                pageCount: pageCount,
                options: options,
                initialState: initialState,
                // 多段巻送り対応: 解決はクロージャ引数 `cur`（=現在スワップ済みの巻）の
                // series/volume を基点にする。serverID/libraryUUID は同一シリーズ内で不変なので
                // 開いた本のものを使う。`cur` を無視して最初の book から再解決すると 2 巻目で
                // 止まる/自動進行が 2 巻目をループする（ローカル/リモートと同じく cur を使う）。
                loadNextVolume: { [store] cur in
                    Self.resolveOfflineVolume(store: store, serverID: serverID, libraryUUID: libraryUUID,
                                              current: cur, direction: .next)
                },
                loadPrevVolume: { [store] cur in
                    Self.resolveOfflineVolume(store: store, serverID: serverID, libraryUUID: libraryUUID,
                                              current: cur, direction: .prev)
                },
                // 進捗を OfflineStore に永続化する（リモートサーバへの POST の代替）。
                persistState: { b, lastPage, _, _ in
                    LastReadTracker.shared.record(.offline(bookID: b.id, title: b.title))
                    store.updateLastPage(serverID: serverID, libraryUUID: libraryUUID, bookID: b.id, page: lastPage)
                },
                // ページレイアウト override はオフラインでは永続化しない（no-op）。
                persistPageOverride: { _, _, _ in },
                // B2: close 時に reload して、保存された lastPage を次回 open に反映する
                // （updateLastPage は .offlineStoreDidChange を post しないため）。
                onClose: { self.viewer = nil; self.reload() },
                suppressResumeDialog: resumeDirect,
                sourceLabel: "オフライン"
            )
            self.viewer = controller
            self.errorText = nil
            controller.present()
        }
    }

    // MARK: - Multi-select state helpers

    private func selectAllVisible() { multiSelection = Set(filtered.map { $0.id }) }

    private func clearSelection() { multiSelection.removeAll() }

    private func deleteSelected() {
        let targets = books.filter { multiSelection.contains($0.id) }
        store.removeBooks(targets)
        multiSelection.removeAll()
        reload()
    }

    /// オフライン保存を削除して一覧を更新する。
    private func delete(_ book: DownloadedBook) {
        store.remove(serverID: book.serverID, libraryUUID: book.libraryUUID, bookID: book.bookID)
        multiSelection.remove(book.id)
        reload()
    }

    /// DL 済の連続隣接巻を解決し NextVolume を組む。該当なし/失敗は nil。
    /// `current` は現在表示中の巻（多段巻送りで毎回更新される）。その series/volume を基点に解決する。
    private static func resolveOfflineVolume(store: OfflineStore, serverID: UUID, libraryUUID: String,
                                             current: BookRow,
                                             direction: OfflineStore.AdjacentDirection) -> NextVolume? {
        guard let series = current.series, let volume = current.volume else { return nil }
        guard let sib = store.adjacentDownloaded(
            serverID: serverID, libraryUUID: libraryUUID,
            series: series, volume: volume, direction: direction) else { return nil }
        let url = store.fileURL(for: sib)
        let row = offlineBookRow(sib, fileURL: url)
        guard let content = try? BookContentFactory.make(for: row) else { return nil }
        let state = ResolvedViewerState(
            spreadEnabled: ViewerSettings.shared.spreadByDefault,
            coverOffset: true,
            lastPage: max(0, sib.lastPage ?? 0),
            overrides: [:]
        )
        return NextVolume(content: content, book: row, state: state)
    }
}
