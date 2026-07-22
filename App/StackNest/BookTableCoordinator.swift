// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import LibraryStore
import AppCore
import OSLog

/// Coordinator for BookTableViewRepresentable. Implements NSTableViewDataSource,
/// NSTableViewDelegate, and NSMenuDelegate via extensions in this file.
///
/// Bridges AppState (Single Source of Truth) and the AppKit NSTableView.
/// All event handlers (sort/selection/column-reorder/double-click/menu) route
/// state changes back through AppState; updateNSView pushes changes the
/// other way via syncFromAppState().
@MainActor
final class BookTableCoordinator: NSObject {
    private static let sortLogger = Logger(subsystem: "app.shelfsmith.stacknest", category: "Sort")

    var appState: AppState
    var settings: LibrarySettings
    weak var tableView: NSTableView?

    /// Header right-click menu for column visibility toggling.
    private var headerMenu: NSMenu?

    /// Last observed value of appState.sortedDisplayedBooksVersion. Used by
    /// syncFromAppState to skip reloadData when the book list is unchanged.
    /// Without this guard, every AppState change (e.g., selection update from
    /// our own delegate) triggers updateNSView → reloadData, which disrupts
    /// in-flight NSTableView mouse tracking and reverts user selection
    /// (Phase 2.4a-table-fix #17). The version counter also catches content
    /// changes (e.g., metadata edits that don't change count or id ordering),
    /// which a shape-only snapshot would miss (#12 list-view stale row).
    private var lastDataVersion: Int = -1

    /// Guard flag: true while installColumns(in:) is programmatically setting
    /// table.sortDescriptors. NSTableView fires sortDescriptorsDidChange even for
    /// programmatic updates, which would reset settings.sortMode to .column and
    /// destroy composite sort (series→volume) on view-mode switches.
    private var isInstallingColumns: Bool = false

    init(appState: AppState, settings: LibrarySettings) {
        self.appState = appState
        self.settings = settings
        super.init()
    }

    /// Visible columns in display order (per settings.listColumnOrder, filtered by listViewColumns).
    /// Title column is always visible.
    var visibleColumns: [BookColumn] {
        settings.listColumnOrder.filter {
            $0.alwaysVisible || settings.listViewColumns.contains($0)
        }
    }

    /// Rebuilds NSTableColumn objects to match visibleColumns.
    /// Removes existing columns first; called from makeNSView and from updateNSView
    /// when listViewColumns or listColumnOrder change.
    func installColumns(in table: NSTableView) {
        table.tableColumns.forEach { table.removeTableColumn($0) }
        let savedWidths = settings.columnWidths
        for col in visibleColumns {
            let nsCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: col.rawValue))
            nsCol.title = settings.label(for: col)
            nsCol.sortDescriptorPrototype = NSSortDescriptor(key: col.rawValue, ascending: true)
            // Restore persisted width; fall back to the column's design default.
            if let w = savedWidths[col.rawValue] {
                nsCol.width = CGFloat(w)
            } else {
                nsCol.width = col.defaultWidth
            }
            nsCol.minWidth = 60
            nsCol.maxWidth = 600
            table.addTableColumn(nsCol)
        }
        // Reflect persisted listViewSort as initial sortDescriptor (header indicator).
        // Guard with isInstallingColumns so that the sortDescriptorsDidChange delegate
        // callback (which fires even for programmatic updates) does not reset sortMode
        // to .column and destroy composite sort (series→volume) during view-mode switches.
        isInstallingColumns = true
        table.sortDescriptors = [
            NSSortDescriptor(
                key: settings.listViewSort.column.rawValue,
                ascending: settings.listViewSort.ascending
            )
        ]
        isInstallingColumns = false
        // Install header right-click menu for column visibility toggling
        installHeaderMenu(in: table)
    }

    /// Builds and attaches a right-click menu on the table header for toggling column visibility.
    private func installHeaderMenu(in table: NSTableView) {
        let menu = NSMenu()
        menu.delegate = self
        for col in BookColumn.allCases where !col.alwaysVisible {
            let item = NSMenuItem(
                title: settings.label(for: col),
                action: #selector(toggleColumnVisibility(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = col
            menu.addItem(item)
        }
        table.headerView?.menu = menu
        headerMenu = menu
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? BookColumn else { return }
        settings.toggleColumn(col)
        if let table = tableView {
            installColumns(in: table)
        }
    }

    /// Handles NSTableView.columnDidResizeNotification. Saves the new width for
    /// the resized column into settings.columnWidths (which auto-persists via didSet).
    @objc func handleColumnResize(_ notification: Notification) {
        guard let nsCol = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        let key = nsCol.identifier.rawValue
        // Only persist widths for columns we recognise (i.e. BookColumn identifiers).
        guard BookColumn(rawValue: key) != nil else { return }
        var widths = settings.columnWidths
        widths[key] = Double(nsCol.width)
        settings.columnWidths = widths
    }

    /// Push AppState changes (selection / data) into NSTableView.
    /// Called from BookTableViewRepresentable.updateNSView when SwiftUI sees state changes.
    ///
    /// All operations are gated on actual diffs — without these guards,
    /// AppState updates from our own delegate would re-enter here and call
    /// reloadData / selectRowIndexes during NSTableView's click tracking,
    /// which causes the click selection to revert (Phase 2.4a-table-fix #17).
    func syncFromAppState() {
        guard let table = tableView else { return }

        let isClickInProgress = (table as? GatedTableView)?.isClickInProgress ?? false
        let version = appState.sortedDisplayedBooksVersion

        // If a user click is mid-flight, buffer this sync until AppKit's
        // mouseDown super returns. Calling reload/selectRowIndexes during the
        // click tracking loop reverts the in-progress selection.
        // Phase 2.4a-table-fix #17.
        if let gatedTable = table as? GatedTableView, gatedTable.isClickInProgress {
            gatedTable.pendingPostClickSync = { [weak self] in
                self?.syncFromAppState()
            }
            return
        }

        let books = appState.sortedDisplayedBooks

        if version != lastDataVersion {
            lastDataVersion = version
            table.reloadData()
        }

        var indices: [Int] = []
        for (idx, book) in books.enumerated() where appState.selectedBookIDs.contains(book.id) {
            indices.append(idx)
        }
        let indexSet = IndexSet(indices)
        if table.selectedRowIndexes != indexSet {
            table.selectRowIndexes(indexSet, byExtendingSelection: false)
        }

        // Reflect persisted sort.
        // When composite sort (seriesVolumeAsc/Desc) is active, clear column sort indicators
        // so the user isn't confused about which sort is in effect.
        // Guard with isInstallingColumns to prevent sortDescriptorsDidChange from
        // resetting sortMode to .column on programmatic updates.
        isInstallingColumns = true
        if settings.sortMode != .column {
            if !table.sortDescriptors.isEmpty {
                table.sortDescriptors = []
            }
        } else {
            let desired = NSSortDescriptor(
                key: settings.listViewSort.column.rawValue,
                ascending: settings.listViewSort.ascending
            )
            if table.sortDescriptors.first?.key != desired.key
               || table.sortDescriptors.first?.ascending != desired.ascending {
                table.sortDescriptors = [desired]
            }
        }
        isInstallingColumns = false

        // Reflect column visibility / order changes
        let currentCols: [BookColumn] = table.tableColumns.compactMap {
            BookColumn(rawValue: $0.identifier.rawValue)
        }
        let desiredCols = visibleColumns
        if currentCols != desiredCols {
            installColumns(in: table)
        } else {
            // 列セットは不変でも、カスタムラベル変更を既存列ヘッダに反映する。
            // installColumns は列セット変更時のみ走るため、表示名だけの変更はここで拾う。
            // .title のみ更新（identifier / sortDescriptorPrototype / width / 列順は保持）。
            for nsCol in table.tableColumns {
                guard let bookCol = BookColumn(rawValue: nsCol.identifier.rawValue) else { continue }
                let newTitle = settings.label(for: bookCol)
                if nsCol.title != newTitle { nsCol.title = newTitle }
            }
        }
    }

    /// Invoked from NSTableView's doubleAction. Opens the clicked book in the external viewer.
    @objc func handleDoubleClick(_ sender: Any?) {
        guard let table = tableView else { return }
        let row = table.clickedRow
        guard row >= 0, row < appState.sortedDisplayedBooks.count else { return }
        let book = appState.sortedDisplayedBooks[row]
        appState.openBooks([book])
    }

    /// Phase 2.5k T3rev2: Return / Enter キーで呼び出される。NSTableView の選択行 (複数可) に対応する
    /// books を AppState.openBooks に渡す（内蔵/外部の分岐は openBooks 側）。grid 側 openSelectedBooks() と同等。
    @objc func handleOpenSelected() {
        guard let table = tableView else { return }
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let books = rows.compactMap { idx -> BookRow? in
            guard idx >= 0, idx < appState.sortedDisplayedBooks.count else { return nil }
            return appState.sortedDisplayedBooks[idx]
        }
        appState.openBooks(books)
    }

    /// Phase 2.5k T3rev3: 先頭行を選択 + scroll (⌘+↑ / Home)。
    @objc func handleSelectFirst() {
        guard let table = tableView else { return }
        let total = appState.sortedDisplayedBooks.count
        guard total > 0 else { return }
        selectAndScrollTable(rowIndex: 0, table: table)
    }

    /// Phase 2.5k T3rev3: 末尾行を選択 + scroll (⌘+↓ / End)。
    @objc func handleSelectLast() {
        guard let table = tableView else { return }
        let total = appState.sortedDisplayedBooks.count
        guard total > 0 else { return }
        selectAndScrollTable(rowIndex: total - 1, table: table)
    }

    /// Phase 2.5k T3rev3: 1 viewport 上の行へ移動 (PageUp)。
    @objc func handlePageUp() {
        guard let table = tableView else { return }
        let total = appState.sortedDisplayedBooks.count
        guard total > 0 else { return }
        let rowsPerPage = computeRowsPerPage(table: table)
        let currentRow = table.selectedRow >= 0 ? table.selectedRow : 0
        let newRow = max(0, currentRow - rowsPerPage)
        selectAndScrollTable(rowIndex: newRow, table: table)
    }

    /// Phase 2.5k T3rev3: 1 viewport 下の行へ移動 (PageDown)。
    @objc func handlePageDown() {
        guard let table = tableView else { return }
        let total = appState.sortedDisplayedBooks.count
        guard total > 0 else { return }
        let rowsPerPage = computeRowsPerPage(table: table)
        let currentRow = table.selectedRow >= 0 ? table.selectedRow : 0
        let newRow = min(total - 1, currentRow + rowsPerPage)
        selectAndScrollTable(rowIndex: newRow, table: table)
    }

    private func computeRowsPerPage(table: NSTableView) -> Int {
        let viewportHeight = table.enclosingScrollView?.documentVisibleRect.height ?? table.bounds.height
        let rowHeight = table.rowHeight + table.intercellSpacing.height
        guard rowHeight > 0 else { return 1 }
        return max(1, Int(viewportHeight / rowHeight))
    }

    /// 単一行を選択して scrollRowToVisible する共通処理。
    /// tableViewSelectionDidChange が AppState.selectedBookIDs / selectedBook を同期するため、
    /// ここでは table 操作のみを行い AppState への直接書き込みは行わない。
    private func selectAndScrollTable(rowIndex: Int, table: NSTableView) {
        table.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        table.scrollRowToVisible(rowIndex)
    }

    /// Invoked from NSTableView.columnDidMoveNotification when user drags a column header.
    /// Persists the new order to settings.listColumnOrder (which auto-saves via didSet).
    @objc func columnDidMove(_ notification: Notification) {
        guard let table = tableView else { return }
        let order: [BookColumn] = table.tableColumns.compactMap {
            BookColumn(rawValue: $0.identifier.rawValue)
        }
        // Append any BookColumn cases not currently visible (so persisted order remains complete)
        let allCases = BookColumn.allCases
        let missing = allCases.filter { !order.contains($0) }
        settings.listColumnOrder = order + missing
    }
}

// MARK: - NSTableViewDataSource
extension BookTableCoordinator: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        appState.sortedDisplayedBooks.count
    }

    /// FX3 A5: list view からの drag-OUT。各選択行について NSTableView が呼ぶので
    /// 1 行 = 1 pasteboard item (book.id を .string で格納)。sidebar の
    /// .dropDestination(for: String.self) が public.utf8-plain-text として受信できるよう
    /// type は必ず .string にする。drop/reorder は実装しない (drag-OUT 専用)。
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let books = appState.sortedDisplayedBooks
        guard row >= 0, row < books.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(books[row].id), forType: .string)
        return item
    }
}

// MARK: - NSTableViewDelegate
extension BookTableCoordinator: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let col = tableColumn,
              let bookCol = BookColumn(rawValue: col.identifier.rawValue),
              row < appState.sortedDisplayedBooks.count else { return nil }
        let book = appState.sortedDisplayedBooks[row]

        let hosting: NSHostingView<AnyView>
        if let reuse = tableView.makeView(withIdentifier: col.identifier, owner: nil)
           as? NSHostingView<AnyView> {
            hosting = reuse
        } else {
            hosting = NSHostingView(rootView: AnyView(EmptyView()))
            hosting.identifier = col.identifier
        }
        hosting.rootView = AnyView(cellContent(for: bookCol, book: book))
        return hosting
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        let selectedIndices = table.selectedRowIndexes
        let books = appState.sortedDisplayedBooks
        let ids = Set(selectedIndices.compactMap { idx -> Int? in
            guard idx < books.count else { return nil }
            return books[idx].id
        })
        if appState.selectedBookIDs != ids {
            appState.selectedBookIDs = ids
        }
        if let firstIdx = selectedIndices.first, firstIdx < books.count {
            appState.selectedBook = books[firstIdx]
        } else {
            appState.selectedBook = nil
        }
    }

    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        // Ignore programmatic sort-descriptor updates from installColumns(in:).
        // NSTableView fires this delegate even for non-user changes; resetting
        // sortMode here would destroy composite sort (series→volume) on view switches.
        guard !isInstallingColumns else { return }

        let start = ContinuousClock().now
        guard let new = tableView.sortDescriptors.first,
              let key = new.key,
              let col = BookColumn(rawValue: key) else { return }
        Self.sortLogger.info("[sort] header click col=\(key, privacy: .public) asc=\(new.ascending)")

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // ヘッダクリックによる単一カラムソートへの切替時に複合ソートを解除する
            settings.sortMode = .column
            settings.listViewSort = ColumnSort(column: col, ascending: new.ascending)
        }

        Task { @MainActor in
            let beforeRefresh = start.duration(to: .now)
            Self.sortLogger.info("[sort] before refresh +\(beforeRefresh.description, privacy: .public)")
            appState.refreshSortedDisplayedBooks()
            tableView.reloadData()
            let afterReload = start.duration(to: .now)
            Self.sortLogger.info("[sort] after reload +\(afterReload.description, privacy: .public)")
        }
    }

    /// SwiftUI content for one cell, dispatched on BookColumn.
    /// Delegates to the shared `bookCellView` in AppCore so local and remote
    /// tables render identically (Phase 4.2c-1 refactor; behavior unchanged).
    @ViewBuilder
    fileprivate func cellContent(for col: BookColumn, book: BookRow) -> some View {
        bookCellView(col, provider: book, settings: settings)
    }

    fileprivate func bookTypeLabel(_ type: Int) -> String {
        settings.bookTypeLabel(type)
    }
}

// MARK: - NSMenuDelegate (Context menu + Header menu)
extension BookTableCoordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Header menu: update check marks + titles to reflect current visibility / custom labels.
        // headerMenu items are built in installHeaderMenu (column-set change only); refresh the
        // display title here so label edits without a set change are also reflected.
        if menu === headerMenu {
            for item in menu.items {
                guard let col = item.representedObject as? BookColumn else { continue }
                item.title = settings.label(for: col)
                item.state = settings.listViewColumns.contains(col) ? .on : .off
            }
            return
        }

        menu.removeAllItems()
        // B24: 項目の有効/無効を明示制御する（自動有効化に任せない）。
        // 他項目は既定 isEnabled=true のまま、「ファイル名をコピー」のみ条件付きで無効化する。
        menu.autoenablesItems = false
        guard let table = tableView else { return }
        let row = table.clickedRow
        guard row >= 0, row < appState.sortedDisplayedBooks.count else { return }
        let book = appState.sortedDisplayedBooks[row]

        // If the right-clicked row isn't already in the selection, replace selection with just it
        if !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }

        let allFav = appState.allSelectedAreFavorites

        // Favorites add/remove (operates on the full selection, matching FX3 add-to-shelf convention)
        let favItem = NSMenuItem(
            title: allFav ? String(localized: "お気に入りから削除") : String(localized: "お気に入りに追加"),
            action: allFav ? #selector(removeFromFavoritesAction(_:)) : #selector(addToFavoritesAction(_:)),
            keyEquivalent: ""
        )
        favItem.target = self
        menu.addItem(favItem)

        menu.addItem(.separator())

        // Rate submenu
        let rateItem = NSMenuItem(title: String(localized: "レート"), action: nil, keyEquivalent: "")
        let rateSubmenu = NSMenu()
        let noRate = NSMenuItem(title: String(localized: "レートなし"),
                                action: #selector(setRatingAction(_:)), keyEquivalent: "")
        noRate.target = self
        noRate.representedObject = 0
        rateSubmenu.addItem(noRate)
        for r in 1...5 {
            let stars = String(repeating: "★", count: r)
            let it = NSMenuItem(title: stars, action: #selector(setRatingAction(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = r
            rateSubmenu.addItem(it)
        }
        rateItem.submenu = rateSubmenu
        menu.addItem(rateItem)

        // Type submenu
        let typeItem = NSMenuItem(title: String(localized: "種類"), action: nil, keyEquivalent: "")
        let typeSubmenu = NSMenu()
        for t in 0...5 {
            let it = NSMenuItem(title: bookTypeLabel(t),
                                action: #selector(setBookTypeAction(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = t
            typeSubmenu.addItem(it)
        }
        typeItem.submenu = typeSubmenu
        menu.addItem(typeItem)

        // Unread toggle
        let unreadItem = NSMenuItem(title: String(localized: "未読チェック"),
                                    action: #selector(toggleUnreadAction(_:)), keyEquivalent: "")
        unreadItem.target = self
        menu.addItem(unreadItem)

        // FX3 A6/A8: シェルフへの追加・除外。
        // 追加 submenu は手動シェルフが 1 件以上あるときのみ。
        // representedObject は shelf id (Int64) を格納する。
        let manualShelves = appState.manualShelves
        if !manualShelves.isEmpty {
            let addShelfItem = NSMenuItem(title: String(localized: "シェルフに追加"),
                                          action: nil, keyEquivalent: "")
            let addShelfSubmenu = NSMenu()
            for shelf in manualShelves {
                let it = NSMenuItem(title: shelf.title,
                                    action: #selector(addToShelfAction(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = shelf.id  // Int64
                addShelfSubmenu.addItem(it)
            }
            addShelfItem.submenu = addShelfSubmenu
            menu.addItem(addShelfItem)
        }
        // 除外は手動シェルフ表示中のみ。
        if case .shelf = appState.selectedSidebarItem {
            let removeShelfItem = NSMenuItem(title: String(localized: "シェルフから外す"),
                                             action: #selector(removeFromShelfAction(_:)), keyEquivalent: "")
            removeShelfItem.target = self
            menu.addItem(removeShelfItem)
        }

        menu.addItem(.separator())

        // Finder で表示
        let finderItem = NSMenuItem(title: String(localized: "Finder で表示"),
                                    action: #selector(revealInFinderAction(_:)), keyEquivalent: "")
        finderItem.target = self
        finderItem.representedObject = book
        menu.addItem(finderItem)

        // ビューアで開く
        let viewerItem = NSMenuItem(title: String(localized: "ビューアで開く"),
                                    action: #selector(openInViewerAction(_:)), keyEquivalent: "")
        viewerItem.target = self
        viewerItem.representedObject = book
        menu.addItem(viewerItem)

        // B24: ファイル名をコピー (単一選択かつ path 非 nil のときのみ有効・拡張子なし)。
        let copyNameItem = NSMenuItem(title: String(localized: "ファイル名をコピー"),
                                      action: #selector(copyFileNameAction(_:)), keyEquivalent: "")
        copyNameItem.target = self
        copyNameItem.representedObject = book
        copyNameItem.isEnabled = (table.selectedRowIndexes.count == 1) && (book.path != nil)
        menu.addItem(copyNameItem)

        menu.addItem(.separator())

        // ファイル名を変更…
        let renameItem = NSMenuItem(
            title: String(localized: "ファイル名を変更…"),
            action: #selector(renameSelectedAction(_:)),
            keyEquivalent: ""
        )
        renameItem.target = self
        menu.addItem(renameItem)

        // ファイルを移動… (shortcut is provided by main menu FileCommands, not context menu)
        let moveItem = NSMenuItem(
            title: String(localized: "ファイルを移動…"),
            action: #selector(moveSelectedAction(_:)),
            keyEquivalent: ""
        )
        moveItem.target = self
        menu.addItem(moveItem)

        // ファイルを再指定… (single-book relink, no file move)
        let relinkItem = NSMenuItem(
            title: String(localized: "ファイルを再指定…"),
            action: #selector(relinkSelectedAction(_:)),
            keyEquivalent: ""
        )
        relinkItem.target = self
        menu.addItem(relinkItem)

        menu.addItem(.separator())

        // ライブラリから削除 (⌫)
        let deleteLibItem = NSMenuItem(
            title: String(localized: "ライブラリから削除"),
            action: #selector(deleteFromLibraryAction(_:)),
            keyEquivalent: ""
        )
        deleteLibItem.target = self
        menu.addItem(deleteLibItem)

        // ファイルをゴミ箱に移動… (⌘⌫)
        let trashItem = NSMenuItem(
            title: String(localized: "ファイルをゴミ箱に移動…"),
            action: #selector(moveToTrashAction(_:)),
            keyEquivalent: ""
        )
        trashItem.target = self
        menu.addItem(trashItem)

        menu.addItem(.separator())

        // 並び替えサブメニュー (Phase 2.4c R1: Grid との UI 統合)
        let sortItem = NSMenuItem(title: String(localized: "並び替え"), action: nil, keyEquivalent: "")
        let sortSubmenu = NSMenu()
        let currentSort = settings.listViewSort
        for col in BookColumn.allCases {
            let it = NSMenuItem(
                title: settings.label(for: col),
                action: #selector(setSortAction(_:)),
                keyEquivalent: ""
            )
            it.target = self
            it.representedObject = col.rawValue
            if settings.sortMode == .column && currentSort.column == col {
                // Grid (SwiftUI Label) と統一: chevron 画像のみで active を示す。
                // NSMenuItem.state = .on を併用すると ✓ と chevron が二重表示になるので未使用。
                it.image = NSImage(
                    systemSymbolName: currentSort.ascending ? "chevron.up" : "chevron.down",
                    accessibilityDescription: nil
                )
            }
            sortSubmenu.addItem(it)
        }
        // 旧「シリーズ → 巻数」複合ソートは廃止。単一カラム「シリーズ」が
        // リモート同様に同一シリーズ内を巻数順に並べる（sortedByColumn(.series)）。
        sortItem.submenu = sortSubmenu
        menu.addItem(sortItem)
    }

    /// Builds the context menu for empty-area right-click (below all rows) in the list view.
    /// Shows book-operation items in a disabled state so the user can see what would be
    /// available if a row were selected, followed by the sort submenu.
    func makeEmptyAreaMenu() -> NSMenu {
        let menu = NSMenu()

        // Book action items — all disabled (行外クリックであることを視覚的に示す)
        let disabledTitles: [String] = [
            String(localized: "お気に入りに追加"),
            String(localized: "レート"),
            String(localized: "種類"),
            String(localized: "未読チェック"),
        ]
        for title in disabledTitles {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let disabledTitles2: [String] = [
            String(localized: "Finder で表示"),
            String(localized: "ビューアで開く"),
        ]
        for title in disabledTitles2 {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let disabledTitles3: [String] = [
            String(localized: "ファイル名を変更…"),
            String(localized: "ファイルを移動…"),
            String(localized: "ファイルを再指定…"),
        ]
        for title in disabledTitles3 {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let disabledTitles4: [String] = [
            String(localized: "ライブラリから削除"),
            String(localized: "ファイルをゴミ箱に移動…"),
        ]
        for title in disabledTitles4 {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Sort submenu (functional — same as in row context menu)
        let sortItem = NSMenuItem(title: String(localized: "並び替え"), action: nil, keyEquivalent: "")
        let sortSubmenu = NSMenu()
        let currentSort = settings.listViewSort
        for col in BookColumn.allCases {
            let it = NSMenuItem(
                title: settings.label(for: col),
                action: #selector(setSortAction(_:)),
                keyEquivalent: ""
            )
            it.target = self
            it.representedObject = col.rawValue
            if settings.sortMode == .column && currentSort.column == col {
                it.image = NSImage(
                    systemSymbolName: currentSort.ascending ? "chevron.up" : "chevron.down",
                    accessibilityDescription: nil
                )
            }
            sortSubmenu.addItem(it)
        }
        // 旧「シリーズ → 巻数」複合ソートは廃止（単一カラム「シリーズ」が巻数順を内包）。
        sortItem.submenu = sortSubmenu
        menu.addItem(sortItem)
        return menu
    }

    @objc private func addToFavoritesAction(_ sender: NSMenuItem) {
        appState.addSelectedBooksToFavorites()
    }

    @objc private func removeFromFavoritesAction(_ sender: NSMenuItem) {
        appState.removeSelectedBooksFromFavorites()
    }

    @objc private func setRatingAction(_ sender: NSMenuItem) {
        guard let rating = sender.representedObject as? Int else { return }
        appState.setRatingForSelected(rating, undoManager: tableView?.window?.undoManager)
    }

    @objc private func setBookTypeAction(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? Int else { return }
        appState.setBookTypeForSelected(type, undoManager: tableView?.window?.undoManager)
    }

    @objc private func toggleUnreadAction(_ sender: NSMenuItem) {
        appState.toggleUnreadForSelected(undoManager: tableView?.window?.undoManager)
    }

    @objc private func revealInFinderAction(_ sender: NSMenuItem) {
        guard let book = sender.representedObject as? BookRow,
              let path = book.path, !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openInViewerAction(_ sender: NSMenuItem) {
        guard let book = sender.representedObject as? BookRow else { return }
        appState.openBooks([book])
    }

    /// B24: 対象本の拡張子なしファイル名をクリップボードへコピー。
    @objc private func copyFileNameAction(_ sender: NSMenuItem) {
        guard let book = sender.representedObject as? BookRow, let path = book.path else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(FileNameUtil.withoutExtension(path: path), forType: .string)
    }

    @objc private func renameSelectedAction(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .renameSelectedBooks, object: nil)
    }

    @objc private func moveSelectedAction(_ sender: Any?) {
        NotificationCenter.default.post(name: .moveSelectedBooks, object: nil)
    }

    @objc private func relinkSelectedAction(_ sender: Any?) {
        // 単一本対象。クリックされた行の book を取得する。
        // moveSelectedAction は notification 経由のため直接 book を持たないが、
        // relink は単一本操作なので table.clickedRow から直接取得する。
        guard let table = tableView else { return }
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < appState.sortedDisplayedBooks.count else { return }
        let book = appState.sortedDisplayedBooks[row]
        guard let db = appState.database else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "「\(book.title)」 にリンクするファイルを選択してください。")
        if let cur = book.path {
            panel.directoryURL = URL(fileURLWithPath: cur).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try db.relinkBook(id: book.id, newPath: url.path(percentEncoded: false))
            try? appState.refreshDisplayedBooks()
            // Review follow-up Important #4: relink 後に表紙・ページ数をサーバ側 relink と
            // 同様に追従させる（失敗は best-effort・relink 自体の成否には影響しない）。
            Task { @MainActor in
                await appState.refreshCoverAndPageCount(afterRelinkOf: book.id)
                try? appState.refreshDisplayedBooks()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "再リンクに失敗しました")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func setSortAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let col = BookColumn(rawValue: raw) else { return }
        // 複合ソートから単一カラムソートに切り替える際に sortMode をリセット
        settings.sortMode = .column
        if settings.listViewSort.column == col {
            settings.listViewSort = ColumnSort(column: col, ascending: !settings.listViewSort.ascending)
        } else {
            settings.listViewSort = ColumnSort(column: col, ascending: true)
        }
        appState.refreshSortedDisplayedBooks()
    }

    @objc private func deleteFromLibraryAction(_ sender: NSMenuItem) {
        handleDeleteFromLibrary()
    }

    @objc private func moveToTrashAction(_ sender: NSMenuItem) {
        handleMoveToTrash()
    }

    // FX3 A6/A8: シェルフへの追加・除外アクション。
    @objc private func addToShelfAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64 else { return }
        appState.addSelectedBooksToShelf(id)
    }

    @objc private func removeFromShelfAction(_ sender: NSMenuItem) {
        appState.removeSelectedBooksFromCurrentShelf()
    }

    // MARK: - Delete helpers (called from menu actions and GatedTableView.keyDown)

    /// ⌫: DB-only delete, Undo 対応 (Task 15).
    /// FX7: scope を見て削除ダイアログを切替。お気に入り/手動シェルフ表示中は 3択
    ///   (シェルフから外す / ライブラリから削除 / キャンセル)、それ以外は従来 2択。
    func handleDeleteFromLibrary() {
        guard let db = appState.database else { return }
        guard !appState.selectedBookIDs.isEmpty else { return }
        BookDeleteCommand.runScopeAwareDelete(
            mode: .library,
            appState: appState,
            database: db,
            bundleURL: appState.bundleURL,
            undoManager: tableView?.window?.undoManager
        )
    }

    /// ⌘⌫: Move files to Trash, then delete from DB.
    /// FX7: scope を見て削除ダイアログを切替。お気に入り/手動シェルフ表示中は 3択
    ///   (シェルフから外す / ゴミ箱に移動 / キャンセル)、それ以外は従来 2択。
    func handleMoveToTrash() {
        guard let db = appState.database else { return }
        guard !appState.selectedBookIDs.isEmpty else { return }
        BookDeleteCommand.runScopeAwareDelete(
            mode: .trash,
            appState: appState,
            database: db,
            bundleURL: appState.bundleURL,
            undoManager: tableView?.window?.undoManager
        )
    }
}
