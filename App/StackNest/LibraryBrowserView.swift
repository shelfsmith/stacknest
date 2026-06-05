// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LibraryStore
import AppCore

// Identifiable wrapper so [BookRow] can be used with sheet(item:).
struct BookRenameSelection: Identifiable {
    let id = UUID()
    let books: [BookRow]
}

struct LibraryBrowserView: View {
    @Bindable var appState: AppState
    @State private var anchorBookID: Int?  // for shift-click range select
    @State private var currentModifiers: NSEvent.ModifierFlags = []
    @State private var modifierMonitor: Any?
    @State private var showLibrarySettings = false
    @State private var showDuplicateScan = false
    @State private var renameSelection: BookRenameSelection?
    /// Task 5: 自 window への参照。openLibrarySettings 通知受信時に key window 判定に使用。
    @State private var hostWindow: NSWindow?
    @State private var gridViewportWidth: CGFloat = 0   // Phase 2.5k T3rev2: window resize 後の列数再計算用
    @State private var gridViewportHeight: CGFloat = 0  // Phase 2.5k T3rev3: PageUp/Down 用
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        mainContent
            .background(
                WindowAccessor { window in
                    // Task 5: capture hosting window for key-window-based filtering
                    if self.hostWindow == nil {
                        self.hostWindow = window
                    }
                }
            )
            .onChange(of: appState.selectedSidebarItem) { _, _ in
                anchorBookID = nil
            }
            .onChange(of: appState.librarySettings?.filterState) { _, _ in
                do { try appState.refreshDisplayedBooks() }
                catch { appState.error = .unexpected(error) }
            }
            .onChange(of: appState.librarySettings?.browserPaneState) { _, _ in
                do { try appState.refreshDisplayedBooks() }
                catch { appState.error = .unexpected(error) }
            }
            .alert("Error", isPresented: errorBinding, presenting: appState.error) { _ in
                Button("OK", role: .cancel) { appState.error = nil }
            } message: { e in
                Text(e.errorDescription ?? "Unknown error")
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: showAddPanel) {
                        Label("追加", systemImage: "plus")
                    }
                    .help("ファイルまたはフォルダを追加")
                }
            }
            .onAppear { startModifierMonitor() }
            .onDisappear { stopModifierMonitor() }
            .sheet(isPresented: $showLibrarySettings) {
                if let settings = appState.librarySettings {
                    LibrarySettingsSheet(
                        settings: settings,
                        bundleName: appState.bundleURL.deletingPathExtension().lastPathComponent,
                        bundleURL: appState.bundleURL,
                        appState: appState
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openLibrarySettings)) { _ in
                // Task 5: 複数 library window が開いている場合、key window のみが反応する。
                // hostWindow が nil の場合は fallback として従来動作 (先頭が開く)。
                guard hostWindow == nil || NSApp.keyWindow === hostWindow else { return }
                showLibrarySettings = true
            }
            // Phase 2.7: 重複検出シート。openLibrarySettings と同 pattern で key window のみ反応。
            .sheet(isPresented: $showDuplicateScan) {
                if let settings = appState.librarySettings, let db = appState.database {
                    DuplicateResolutionSheet(
                        settings: settings,
                        database: db,
                        bundleURL: appState.bundleURL,
                        appState: appState
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openDuplicateScan)) { _ in
                guard hostWindow == nil || NSApp.keyWindow === hostWindow else { return }
                showDuplicateScan = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .renameSelectedBooks)) { _ in
                showRenameSheet()
            }
            .sheet(item: $renameSelection) { sel in
                if let db = appState.database,
                   let format = try? FilenameFormat(raw: appState.librarySettings?.filenameFormat ?? "@title") {
                    BookFileRenameSheet(
                        books: sel.books,
                        format: format,
                        database: db,
                        onComplete: { _ in
                            do { try appState.refreshDisplayedBooks() }
                            catch { appState.error = .unexpected(error) }
                        },
                        bookTypeLabelOverrides: appState.librarySettings?.bookTypeLabelOverrides ?? [:]
                    )
                }
            }
            .onDrop(of: [.fileURL], delegate: BookDropDelegate { urls in
                handleAdd(urls: urls)
            })
            .onReceive(NotificationCenter.default.publisher(for: .toggleTopPaneMode)) { _ in
                guard let settings = appState.librarySettings else { return }
                let next: String
                switch settings.topPaneMode {
                case "browse": next = "stamp"
                case "stamp":  next = "hidden"
                default:       next = "browse"
                }
                settings.topPaneMode = next
            }
            .onReceive(NotificationCenter.default.publisher(for: .moveSelectedBooks)) { _ in
                moveSelectedBooks()
            }
            // M2-2-v3: body レベルで selectAll を受信することで、list/grid 両 view で全選択が動く。
            // grid view 内の gridContent.onReceive は grid 表示時のみ生きているため、
            // body レベルでも受信する必要がある。
            // Fix 5: 複数 library window が開いている場合、frontmost (key) window のみが反応する。
            // Phase 2.5b-ext-v4 の openLibrarySettings と同 pattern。
            .onReceive(NotificationCenter.default.publisher(for: .stacknestSelectAllRequest)) { _ in
                guard hostWindow == nil || NSApp.keyWindow === hostWindow else { return }
                appState.selectAllInCurrentView()
            }
            // Task 6: context menu の keyboardShortcut 表記削除対応。main menu からの削除/ゴミ箱通知を受信。
            // Task 15: DeleteBooksCommand 経由 (Undo 対応)。
            // FX7: scope-aware な 3 択ダイアログを経由する（Delete キーと同一パス）。
            .onReceive(NotificationCenter.default.publisher(for: .stacknestDeleteFromLibraryRequest)) { _ in
                guard !appState.selectedBookIDs.isEmpty, let db = appState.database else { return }
                BookDeleteCommand.runScopeAwareDelete(
                    mode: .library,
                    appState: appState,
                    database: db,
                    bundleURL: appState.bundleURL,
                    undoManager: undoManager
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .stacknestMoveToTrashRequest)) { _ in
                guard !appState.selectedBookIDs.isEmpty, let db = appState.database else { return }
                BookDeleteCommand.runScopeAwareDelete(
                    mode: .trash,
                    appState: appState,
                    database: db,
                    bundleURL: appState.bundleURL,
                    undoManager: undoManager
                )
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            if let settings = appState.librarySettings {
                switch settings.topPaneMode {
                case "browse":
                    BrowserPaneView(appState: appState, settings: settings)
                    Divider()
                case "stamp":
                    StampPaneView(appState: appState)
                    Divider()
                case "hidden":
                    EmptyView()
                default:
                    BrowserPaneView(appState: appState, settings: settings)
                    Divider()
                }
            }
            // Grid view 表示時のみ sub-toolbar を挿入
            if appState.viewMode == .grid, let settings = appState.librarySettings {
                GridSubToolbar(settings: settings)
                Divider()
            }

            Group {
                if appState.sortedDisplayedBooks.isEmpty {
                    emptyStateView
                } else {
                    switch appState.viewMode {
                    case .grid:
                        gridContent
                    case .list:
                        if let settings = appState.librarySettings {
                            BookListView(appState: appState, settings: settings)
                        } else {
                            gridContent  // fallback if settings not yet loaded
                        }
                    }
                }
            }
            // ContentUnavailableView の自然サイズだけだと VStack が中央寄せされて
            // Browser pane の上に大きな空白が出るため、Group を expand させる。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 空状態の表示（FX2 A8-empty）。
    /// ライブラリ未ロード or ライブラリ自体が空のときだけ「インポート促し」を出し、
    /// ライブラリは読み込まれているが現在のスコープ/フィルタで 0 件のときは中立的な
    /// 「該当する書籍がありません」を出す。
    @ViewBuilder
    private var emptyStateView: some View {
        if appState.database == nil || appState.libraryBookCount == 0 {
            ContentUnavailableView(
                "No library yet",
                systemImage: "books.vertical",
                description: Text("Import a Stackroom XML, or add new books.")
            )
        } else {
            ContentUnavailableView(
                "該当する書籍がありません",
                systemImage: "tray",
                description: Text("このシェルフ・絞り込み条件に一致する書籍はありません。")
            )
        }
    }

    // MARK: - Add panel

    private func showAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        // Phase 2.5g+h+i fixup v1: 単独 image / pdf / movie / text も追加対象に。
        // 既存 archive 系 + folder + image / pdf / movie / text の包括 UTType を許可する。
        panel.allowedContentTypes = [
            // archive
            .zip,
            UTType("app.shelfsmith.stacknest.cbz") ?? .zip,
            UTType("app.shelfsmith.stacknest.cbr") ?? .data,
            UTType("public.7z-archive") ?? .data,
            UTType("com.rarlab.rar-archive") ?? .data,
            // folder
            .folder,
            // single files (B18 + B20 + B21)
            .image,           // jpg/png/gif/webp/heic を包含
            .pdf,
            .movie,           // mp4/mov/m4v を包含
            .plainText,
            UTType("org.idpf.epub-container") ?? .data
        ]
        if panel.runModal() == .OK {
            handleAdd(urls: panel.urls)
        }
    }

    private func handleAdd(urls: [URL]) {
        guard let db = appState.database else { return }
        Task {
            let format = (try? FilenameFormat(raw: appState.librarySettings?.filenameFormat ?? "@title"))
                ?? (try! FilenameFormat(raw: "@title"))
            let coord = BookAddCoordinator(
                database: db,
                bundleURL: appState.bundleURL,
                format: format
            )
            let result = await coord.add(urls: urls)
            do { try appState.refreshDisplayedBooks() }
            catch { appState.error = .unexpected(error) }
            if !result.alreadyPresent.isEmpty {
                let alert = NSAlert()
                alert.messageText = "\(result.alreadyPresent.count) 件は既に登録済みです"
                alert.runModal()
            }
        }
    }

    // MARK: - Modifier monitor

    private func startModifierMonitor() {
        guard modifierMonitor == nil else { return }
        // 登録時点の modifier state を取得して初期値を確実に空にする。
        // NSEvent.modifierFlags は launchd 経由の起動時に不定値を返す場合がある。
        // flagsChanged が届く前に click が来ても currentModifiers = [] を保証する。
        currentModifiers = []
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return event
        }
    }

    private func stopModifierMonitor() {
        if let monitor = modifierMonitor {
            NSEvent.removeMonitor(monitor)
            modifierMonitor = nil
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        // M1-2-v3: GeometryReader で viewport 高さを取得し、ZStack 最下層に Color.clear を置いて
        // contentShape(Rectangle()) + onTapGesture で全空白領域のタップを受ける。
        // .background() modifier に onTapGesture を付けると hit-testing が無効なため動作しない。
        // Phase 2.5k: ScrollViewReader で proxy を取り出し、矢印 navigation で scrollTo できるようにする。
        GeometryReader { geo in
        ScrollViewReader { scrollProxy in
        ScrollView {
            ZStack(alignment: .topLeading) {
                // 空白タップで選択解除 (最下層)
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    .onTapGesture {
                        appState.selectedBookIDs = []
                    }

                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                    ForEach(appState.sortedDisplayedBooks, id: \.id) { book in
                        BookCell(book: book, loader: appState.thumbnailLoader)
                            .id(book.id)  // Phase 2.5k: scrollProxy.scrollTo(book.id) で参照
                            // FX3 A4: 選択中セルを drag したときは選択全体を運ぶ。
                            // 複数選択は comma-joined 文字列 ("1,2,3")、単体は "5"。
                            // drop 側は受信文字列を "," で split → Int 化して両方を統一処理。
                            .draggable(
                                appState.selectedBookIDs.contains(book.id) && appState.selectedBookIDs.count > 1
                                    ? appState.selectedBookIDs.sorted().map(String.init).joined(separator: ",")
                                    : String(book.id)
                            )
                            .contentShape(Rectangle())
                            // Double-tap (no modifier) → open viewer
                            .onTapGesture(count: 2) {
                                appState.selectedBookIDs = [book.id]
                                appState.selectedBook = book
                                anchorBookID = book.id
                                appState.openBooks([book])
                            }
                            // Single-click: cmd/shift/plain decided by currentModifiers (NSEvent monitor)
                            .onTapGesture {
                                handleGridClick(book: book)
                            }
                            .background(
                                appState.selectedBookIDs.contains(book.id)
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear
                            )
                            .contextMenu {
                                bookActionMenuItems(book: book, enabled: true)
                                Divider()
                                sortSubMenu()
                            }
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
        }
        .focusable()
        .focusEffectDisabled()
        .onAppear {
            gridViewportWidth = geo.size.width
            gridViewportHeight = geo.size.height
        }
        .onChange(of: geo.size.width) { _, new in gridViewportWidth = new }
        .onChange(of: geo.size.height) { _, new in gridViewportHeight = new }
        // Phase 2.5k T3rev: focus を持つ view 自身 (= ScrollView に .focusable()) に
        // onKeyPress 群を attach する。bc2740f では .onKeyPress を ScrollView の外側 (=
        // focusable の外側の ScrollViewReader 層) に置いており、SwiftUI の .onKeyPress 仕様
        // (handler view 自身または descendant が focus を持つときのみ発火) を満たさず矢印が
        // 全く発火しなかった (smoke v1 NG)。
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: .down) { press in
            // Caps Lock や .numericPad は無視し、shift/⌘/option/control だけを「修飾子付き」とみなす。
            let active: EventModifiers = [.shift, .command, .option, .control]
            let mods = press.modifiers.intersection(active)
            let books = appState.sortedDisplayedBooks
            guard !books.isEmpty else { return .ignored }

            // press.key → direction を先に解決
            let direction: GridNavigator.Direction
            switch press.key {
            case .upArrow:    direction = .up
            case .downArrow:  direction = .down
            case .leftArrow:  direction = .left
            case .rightArrow: direction = .right
            default: return .ignored
            }

            // ⌘+矢印 の分岐: ⌘+↑ / ⌘+↓ = 先頭/末尾ジャンプ。⌘+← / ⌘+→ = no-op だが key 消費。
            if mods == [.command] {
                switch direction {
                case .up:
                    if let firstIdx = GridNavigator.firstIndex(total: books.count) {
                        selectAndScrollGrid(books: books, targetIndex: firstIdx, scrollProxy: scrollProxy)
                    }
                case .down:
                    if let lastIdx = GridNavigator.lastIndex(total: books.count) {
                        selectAndScrollGrid(books: books, targetIndex: lastIdx, scrollProxy: scrollProxy)
                    }
                case .left, .right:
                    break  // no-op だが下で .handled を返して system 標準動作の暴発を防ぐ
                }
                return .handled
            }

            // option / control 単独 (または shift 以外との組み合わせ) は無視
            guard mods.subtracting([.shift]).isEmpty else { return .ignored }

            // anchor が有効と認める条件: anchorBookID が books に存在 かつ selectedBookIDs に含まれる。
            // empty selection / 残留 anchor は invalid 扱い → 先頭リセット (Finder 準拠)。
            // これにより「何も選択していない状態 + 矢印 → 先頭選択」が安定する。
            let resolvedAnchorIndex: Int? = {
                guard let anchor = anchorBookID,
                      appState.selectedBookIDs.contains(anchor),
                      let idx = books.firstIndex(where: { $0.id == anchor })
                else { return nil }
                return idx
            }()

            guard let anchorIndex = resolvedAnchorIndex else {
                selectAndScrollGrid(books: books, targetIndex: 0, scrollProxy: scrollProxy)
                return .handled
            }

            // shift+矢印 のときは cursor (= 前回 selectedBook) から進める。それ以外は anchor から。
            let startIndex: Int
            if mods.contains(.shift),
               let cursorID = appState.selectedBook?.id,
               let cursorIdx = books.firstIndex(where: { $0.id == cursorID }) {
                startIndex = cursorIdx
            } else {
                startIndex = anchorIndex
            }

            // 列数計算 → newIndex
            // Phase 2.5k T3rev2: geo.size.width の代わりに @State の gridViewportWidth を使用。
            // .onKeyPress closure 内では SwiftUI attribute graph が geo.size.width を再評価しない
            // ため、window resize 後も古い幅が読まれて列数がずれる。gridViewportWidth は
            // onAppear + onChange(of: geo.size.width) 経由で常に最新値に同期済み。
            let itemSize = appState.librarySettings?.gridItemSize ?? 160
            let columns = GridColumnCalculator.columns(
                viewportWidth: gridViewportWidth,
                itemMinSize: itemSize,
                spacing: 16
            )
            guard let newIndex = GridNavigator.nextIndex(
                current: startIndex,
                direction: direction,
                total: books.count,
                columns: columns
            ) else {
                return .handled  // 端で stop、キー消費
            }

            let target = books[newIndex]
            if mods.contains(.shift) {
                // shift+矢印: anchor 固定、anchor〜newIndex を selection に (Finder 同様)
                let lo = min(anchorIndex, newIndex)
                let hi = max(anchorIndex, newIndex)
                appState.selectedBookIDs = Set(books[lo...hi].map(\.id))
                appState.selectedBook = target  // cursor は newIndex の book
                // anchorBookID は変更しない
                scrollProxy.scrollTo(target.id, anchor: .center)
            } else {
                // plain 矢印: 単一選択 + anchor 更新
                selectAndScrollGrid(books: books, targetIndex: newIndex, scrollProxy: scrollProxy)
            }
            return .handled
        }
        // Phase 2.5k T3rev2: grid 側 Enter キーで開く。
        .onKeyPress(keys: [.return], phases: .down) { _ in
            let books = appState.sortedDisplayedBooks
            guard !books.isEmpty else { return .ignored }
            openSelectedBooks()
            return .handled
        }
        // Phase 2.5k T3rev3: テンキー Enter (= NSEvent keyCode 76) は SwiftUI .onKeyPress(.return)
        // では捕捉できないため、Character("\u{0003}") (END OF TEXT) で別途 attach する。
        // macOS は numericPad の Enter キーをこの character として届ける。
        .onKeyPress(KeyEquivalent(Character("\u{0003}")), phases: .down) { _ in
            let books = appState.sortedDisplayedBooks
            guard !books.isEmpty else { return .ignored }
            openSelectedBooks()
            return .handled
        }
        // Phase 2.5k T3rev3: Home/End で先頭/末尾、PageUp/Down で 1 viewport 分の上下移動。
        // grid + list で操作統一感のため。
        .onKeyPress(keys: [.home, .end, .pageUp, .pageDown], phases: .down) { press in
            let books = appState.sortedDisplayedBooks
            guard !books.isEmpty else { return .ignored }

            switch press.key {
            case .home:
                if let idx = GridNavigator.firstIndex(total: books.count) {
                    selectAndScrollGrid(books: books, targetIndex: idx, scrollProxy: scrollProxy)
                }
                return .handled
            case .end:
                if let idx = GridNavigator.lastIndex(total: books.count) {
                    selectAndScrollGrid(books: books, targetIndex: idx, scrollProxy: scrollProxy)
                }
                return .handled
            case .pageUp, .pageDown:
                // 1 ページ分の行数 = viewport.height / (itemSize + spacing)
                let itemSize = appState.librarySettings?.gridItemSize ?? 160
                let rowStride = itemSize + 16
                let rowsPerPage = max(1, Int(gridViewportHeight / rowStride))
                let columns = GridColumnCalculator.columns(
                    viewportWidth: gridViewportWidth,
                    itemMinSize: itemSize,
                    spacing: 16
                )
                let pageDelta = rowsPerPage * columns

                // 現在 index: anchor が valid ならそれ、なければ先頭から
                let resolvedAnchorIndex: Int? = {
                    guard let anchor = anchorBookID,
                          appState.selectedBookIDs.contains(anchor),
                          let idx = books.firstIndex(where: { $0.id == anchor })
                    else { return nil }
                    return idx
                }()
                let currentIndex = resolvedAnchorIndex ?? 0
                let rawIndex = press.key == .pageDown
                    ? currentIndex + pageDelta
                    : currentIndex - pageDelta
                let clampedIndex = max(0, min(books.count - 1, rawIndex))
                selectAndScrollGrid(books: books, targetIndex: clampedIndex, scrollProxy: scrollProxy)
                return .handled
            default:
                return .ignored
            }
        }
        .onKeyPress(keys: [KeyEquivalent("a")], phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            appState.selectedBookIDs = Set(appState.sortedDisplayedBooks.map(\.id))
            return .handled
        }
        .onKeyPress(keys: [.delete], phases: .down) { press in
            guard !appState.selectedBookIDs.isEmpty, let db = appState.database else { return .ignored }
            // FX7: scope を見て削除ダイアログを切替。お気に入り/手動シェルフ表示中は 3択
            //   (シェルフから外す / 破壊的削除 / キャンセル)、それ以外は従来 2択。
            //   ⌘⌫ → ゴミ箱モード、⌫ → ライブラリ削除モード。
            BookDeleteCommand.runScopeAwareDelete(
                mode: press.modifiers.contains(.command) ? .trash : .library,
                appState: appState,
                database: db,
                bundleURL: appState.bundleURL,
                undoManager: undoManager
            )
            return .handled
        }
        }  // ScrollViewReader (Phase 2.5k T3rev: focus + key handlers consolidated here)
        .contextMenu {
            // 余白右クリック: 選択中 book があれば Book actions を disabled で表示し
            // 並び替えサブメニューだけ active に。選択 book がない場合は Sort のみ表示。
            if !appState.selectedBookIDs.isEmpty,
               let book = appState.sortedDisplayedBooks.first(where: { appState.selectedBookIDs.contains($0.id) }) {
                bookActionMenuItems(book: book, enabled: false)
                Divider()
            }
            sortSubMenu()
        }
        // M2-2: Grid 表示時は LazyVGrid が NSResponder.selectAll(_:) を提供しないため
        // Edit menu「すべてを選択」が grey out になる。Notification 経由で常時有効な全選択を提供。
        // M2-2-v3: selectAllInCurrentView() でグリッド/リスト両対応の全選択を行う。
        // AppState.selectedBookIDs (@Published) の変更は syncFromAppState() 経由で
        // NSTableView (list view) にも反映される。
        // Fix 5: body レベルの onReceive と同じく、key window のみが反応するようにガード。
        .onReceive(NotificationCenter.default.publisher(for: .stacknestSelectAllRequest)) { _ in
            guard hostWindow == nil || NSApp.keyWindow === hostWindow else { return }
            appState.selectAllInCurrentView()
        }
        } // end GeometryReader
    }

    /// Book アクションメニューの中身。enabled=false で全項目 disabled (Grid 余白右クリック時)。
    @ViewBuilder
    private func bookActionMenuItems(book: BookRow, enabled: Bool) -> some View {
        Button(appState.allSelectedAreFavorites ? "お気に入りから削除" : "お気に入りに追加") {
            ensureSelected(book)
            if appState.allSelectedAreFavorites {
                appState.removeSelectedBooksFromFavorites()
            } else {
                appState.addSelectedBooksToFavorites()
            }
        }
        .disabled(!enabled)
        Divider()
        ratingMenu(forContextBook: book)
            .disabled(!enabled)
        typeMenu(forContextBook: book)
            .disabled(!enabled)
        Button("未読チェック") {
            ensureSelected(book)
            appState.toggleUnreadForSelected()
        }
        .disabled(!enabled)
        // FX3 A6/A8: シェルフへの追加・除外 (cell の enabled menu のみ。
        // 余白の disabled menu には出さない)。
        if enabled {
            if !appState.manualShelves.isEmpty {
                Menu("シェルフに追加") {
                    ForEach(appState.manualShelves, id: \.id) { shelf in
                        Button(shelf.title) {
                            ensureSelected(book)
                            appState.addSelectedBooksToShelf(shelf.id)
                        }
                    }
                }
            }
            if case .shelf = appState.selectedSidebarItem {
                Button("シェルフから外す") {
                    ensureSelected(book)
                    appState.removeSelectedBooksFromCurrentShelf()
                }
            }
        }
        Divider()
        Button("Finder で表示") {
            guard let path = book.path, !path.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        .disabled(!enabled)
        Button("ビューワで開く") {
            appState.openBooks([book])
        }
        .disabled(!enabled)
        Divider()
        // Task 6: context menu の keyboardShortcut 表記削除。
        // ショートカット動作は main menu (FileCommands) の定義で維持する。
        Button("ファイル名を変更…") {
            ensureSelected(book)
            showRenameSheet()
        }
        .disabled(!enabled)
        Button("ファイルを移動…") {
            ensureSelected(book)
            moveSelectedBooks()
        }
        .disabled(!enabled || appState.displayedSelectedBooks.isEmpty)
        Divider()
        Button("ライブラリから削除") {
            ensureSelected(book)
            guard let db = appState.database else { return }
            let ids = Array(appState.selectedBookIDs)
            BookDeleteCommand.deleteFromLibrary(
                bookIDs: ids,
                database: db,
                bundleURL: appState.bundleURL,
                appState: appState,
                undoManager: undoManager
            )
        }
        .disabled(!enabled)
        Button("ファイルをゴミ箱に移動…") {
            ensureSelected(book)
            guard let db = appState.database else { return }
            let books = appState.displayedSelectedBooks.compactMap { b -> (id: Int, url: URL)? in
                guard let path = b.path, !path.isEmpty else { return nil }
                return (id: b.id, url: URL(fileURLWithPath: path))
            }
            guard !books.isEmpty else { return }
            let removed = BookDeleteCommand.moveToTrash(
                books: books,
                database: db,
                bundleURL: appState.bundleURL
            )
            if !removed.isEmpty {
                do { try appState.refreshDisplayedBooks() }
                catch { appState.error = .unexpected(error) }
            }
        }
        .disabled(!enabled)
    }

    /// 「並び替え」サブメニュー。Cell / 余白いずれの context menu からも常に enabled。
    @ViewBuilder
    private func sortSubMenu() -> some View {
        if let settings = appState.librarySettings {
            Menu("並び替え") {
                GridSortContextMenu(settings: settings) {
                    appState.refreshSortedDisplayedBooks()
                }
            }
        }
    }

    /// ⌘-click: toggle this book in selectedBookIDs.
    private func toggleSelection(book: BookRow) {
        if appState.selectedBookIDs.contains(book.id) {
            appState.selectedBookIDs.remove(book.id)
            if appState.selectedBook?.id == book.id {
                if let firstID = appState.selectedBookIDs.first,
                   let other = appState.sortedDisplayedBooks.first(where: { $0.id == firstID }) {
                    appState.selectedBook = other
                } else {
                    appState.selectedBook = nil
                }
            }
        } else {
            appState.selectedBookIDs.insert(book.id)
            appState.selectedBook = book
            anchorBookID = book.id
        }
    }

    /// ⇧-click: range select from anchor to this book.
    private func rangeSelect(to book: BookRow) {
        let books = appState.sortedDisplayedBooks
        guard let anchor = anchorBookID,
              let anchorIdx = books.firstIndex(where: { $0.id == anchor }),
              let clickedIdx = books.firstIndex(where: { $0.id == book.id }) else {
            // No anchor or anchor not in displayedBooks — fall through to single replace
            replaceSelection(book: book)
            return
        }
        let lo = min(anchorIdx, clickedIdx)
        let hi = max(anchorIdx, clickedIdx)
        appState.selectedBookIDs = Set(books[lo...hi].map(\.id))
        appState.selectedBook = book
    }

    /// Single-tap handler: branches on currentModifiers (continuously tracked via NSEvent monitor).
    private func handleGridClick(book: BookRow) {
        if currentModifiers.contains(.command) {
            toggleSelection(book: book)
        } else if currentModifiers.contains(.shift) {
            rangeSelect(to: book)
        } else {
            replaceSelection(book: book)
        }
    }

    /// Phase 2.5k T3rev3: 単一選択 + anchor 更新 + scrollTo の共通処理。
    /// 矢印 navigation / 先頭・末尾ジャンプ / PageUp/Down で共有される。
    private func selectAndScrollGrid(books: [BookRow], targetIndex: Int, scrollProxy: ScrollViewProxy) {
        let target = books[targetIndex]
        appState.selectedBookIDs = [target.id]
        appState.selectedBook = target
        anchorBookID = target.id
        scrollProxy.scrollTo(target.id, anchor: .center)
    }

    /// Phase 2.5k T3rev2: 選択中の books (or fallback to anchor) を外部 viewer で開く。
    /// Enter キー (grid)、および NSTableView の Return キー経由で共有される。
    private func openSelectedBooks() {
        let books = appState.sortedDisplayedBooks
        let selected = books.filter { appState.selectedBookIDs.contains($0.id) }
        let openTargets: [BookRow]
        if !selected.isEmpty {
            openTargets = selected
        } else if let anchor = anchorBookID, let book = books.first(where: { $0.id == anchor }) {
            openTargets = [book]
        } else {
            openTargets = []
        }
        appState.openBooks(openTargets)
    }

    /// Plain click: replace selection.
    private func replaceSelection(book: BookRow) {
        appState.selectedBookIDs = [book.id]
        appState.selectedBook = book
        anchorBookID = book.id
    }

    private var gridColumns: [GridItem] {
        let size = appState.librarySettings?.gridItemSize ?? 160
        // R1-2-v3: minimum/maximum を同値に固定することで slider 連続値変化が直接 cell size に反映される。
        // .adaptive(minimum:) のみだと列数変化閾値までセルが伸縮して slider 変化が見えない。
        return [GridItem(.adaptive(minimum: size, maximum: size), spacing: 16)]
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appState.error != nil },
            set: { if !$0 { appState.error = nil } }
        )
    }

    /// If the right-clicked book isn't already in selectedBookIDs, replace selection with just this book.
    private func ensureSelected(_ book: BookRow) {
        if !appState.selectedBookIDs.contains(book.id) {
            appState.selectedBookIDs = [book.id]
            appState.selectedBook = book
        }
    }

    @ViewBuilder
    private func ratingMenu(forContextBook book: BookRow) -> some View {
        Menu("レート") {
            Button("レートなし") {
                ensureSelected(book)
                appState.setRatingForSelected(0)
            }
            ForEach(1...5, id: \.self) { rating in
                Button(String(repeating: "★", count: rating)) {
                    ensureSelected(book)
                    appState.setRatingForSelected(rating)
                }
            }
        }
    }

    @ViewBuilder
    private func typeMenu(forContextBook book: BookRow) -> some View {
        Menu("種類") {
            ForEach(0...5, id: \.self) { typeID in
                Button(typeLabel(typeID)) {
                    ensureSelected(book)
                    appState.setBookTypeForSelected(typeID)
                }
            }
        }
    }

    private func typeLabel(_ id: Int) -> String {
        appState.librarySettings?.bookTypeLabel(id) ?? BookTypeLabel.canonicalLabel(for: id)
    }

    /// Opens the rename sheet for the currently selected books.
    private func showRenameSheet() {
        let books = appState.displayedSelectedBooks
        guard !books.isEmpty else { return }
        renameSelection = BookRenameSelection(books: books)
    }

    /// Runs the move-files flow for the currently selected books.
    private func moveSelectedBooks() {
        guard let db = appState.database else { return }
        let books = appState.displayedSelectedBooks.compactMap { row -> (id: Int, sourceURL: URL)? in
            guard let path = row.path else { return nil }
            return (id: row.id, sourceURL: URL(fileURLWithPath: path))
        }
        guard !books.isEmpty else { return }
        BookMoveCommand.runMoveFlow(books: books, database: db)
        try? appState.refreshDisplayedBooks()
    }
}
