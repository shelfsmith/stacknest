// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import AppCore
import LibraryServerAPI

/// リモートのリスト表示。ローカル NSTableView と同じ列モデル（BookColumn/LibrarySettings）と
/// セル描画（bookCellView）を使い、配線先を RemoteLibraryState にしたリモート専用版。
struct RemoteBookTableViewRepresentable: NSViewRepresentable {
    @Bindable var state: RemoteLibraryState
    @Bindable var settings: LibrarySettings

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let table = NSTableView()
        table.allowsMultipleSelection = true
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.doubleAction = #selector(RemoteBookTableCoordinator.handleDoubleClick(_:))
        table.target = context.coordinator
        context.coordinator.tableView = table
        context.coordinator.installColumns(in: table)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(RemoteBookTableCoordinator.columnDidMove(_:)),
            name: NSTableView.columnDidMoveNotification, object: table)
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(RemoteBookTableCoordinator.handleColumnResize(_:)),
            name: NSTableView.columnDidResizeNotification, object: table)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(RemoteBookTableCoordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        context.coordinator.scrollView = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        _ = state.downloadedVersion   // observe so updateNSView re-runs when DL state changes
        let coord = context.coordinator
        coord.state = state
        coord.settings = settings
        coord.syncRequestedFields()
        coord.syncFromState()
    }

    func makeCoordinator() -> RemoteBookTableCoordinator {
        RemoteBookTableCoordinator(state: state, settings: settings)
    }
}

@MainActor
final class RemoteBookTableCoordinator: NSObject {
    var state: RemoteLibraryState
    var settings: LibrarySettings
    weak var tableView: NSTableView?
    weak var scrollView: NSScrollView?
    private var headerMenu: NSMenu?
    private var isInstallingColumns = false
    private var lastBooksVersion = -1
    private var lastDownloadedVersion = -1

    /// リモート専用「DL（ダウンロード済み）」列の識別子。BookColumn ではない sentinel。
    private static let downloadColumnID = "__remote_downloaded__"

    init(state: RemoteLibraryState, settings: LibrarySettings) {
        self.state = state; self.settings = settings; super.init()
    }

    var visibleColumns: [BookColumn] {
        settings.listColumnOrder.filter { $0.alwaysVisible || settings.listViewColumns.contains($0) }
    }

    func installColumns(in table: NSTableView) {
        isInstallingColumns = true
        defer { isInstallingColumns = false }
        table.tableColumns.forEach { table.removeTableColumn($0) }
        let dlCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: Self.downloadColumnID))
        dlCol.title = "DL"
        dlCol.width = 36
        dlCol.minWidth = 36
        dlCol.maxWidth = 44
        // ソート対象外（sortDescriptorPrototype を設定しない）。
        table.addTableColumn(dlCol)
        let savedWidths = settings.columnWidths
        for col in visibleColumns {
            let nsCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: col.rawValue))
            nsCol.title = settings.label(for: col)
            nsCol.sortDescriptorPrototype = NSSortDescriptor(key: col.rawValue, ascending: true)
            nsCol.width = savedWidths[col.rawValue].map { CGFloat($0) } ?? col.defaultWidth
            nsCol.minWidth = 40
            nsCol.maxWidth = 600
            table.addTableColumn(nsCol)
        }
        installHeaderMenu(in: table)
    }

    private func installHeaderMenu(in table: NSTableView) {
        let menu = NSMenu()
        menu.delegate = self
        for col in BookColumn.allCases where !col.alwaysVisible {
            let item = NSMenuItem(title: settings.label(for: col),
                                  action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
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
        if let table = tableView { installColumns(in: table) }
        syncRequestedFields(forceReloadIfChanged: true)
    }

    @objc func handleColumnResize(_ notification: Notification) {
        guard let nsCol = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              BookColumn(rawValue: nsCol.identifier.rawValue) != nil else { return }
        var widths = settings.columnWidths
        widths[nsCol.identifier.rawValue] = Double(nsCol.width)
        settings.columnWidths = widths
    }

    @objc func columnDidMove(_ notification: Notification) {
        guard let table = tableView else { return }
        let order: [BookColumn] = table.tableColumns.compactMap { BookColumn(rawValue: $0.identifier.rawValue) }
        let missing = BookColumn.allCases.filter { !order.contains($0) }
        settings.listColumnOrder = order + missing
    }

    func syncRequestedFields(forceReloadIfChanged: Bool = false) {
        let fields = RemoteListFields.fields(for: Set(visibleColumns))
        if fields != state.requestedFields {
            let added = !fields.subtracting(state.requestedFields).isEmpty
            state.requestedFields = fields
            if forceReloadIfChanged && added {
                Task { await state.reload() }
            }
        }
    }

    func syncFromState() {
        guard let table = tableView else { return }
        if state.booksVersion != lastBooksVersion || state.downloadedVersion != lastDownloadedVersion {
            lastBooksVersion = state.booksVersion
            lastDownloadedVersion = state.downloadedVersion
            table.reloadData()
        }
        let current: [BookColumn] = table.tableColumns.compactMap { BookColumn(rawValue: $0.identifier.rawValue) }
        if current != visibleColumns { installColumns(in: table) }
        // ヘッダのソートインジケータ（▲▼）を現在のソートに合わせる。
        // state.sortKey は serverSortKey 文字列なので、それに一致する列の rawValue を
        // sortDescriptor の key にする（列ヘッダの identifier は col.rawValue のため）。
        isInstallingColumns = true
        if let col = BookColumn.allCases.first(where: { $0.serverSortKey == state.sortKey }) {
            let desired = NSSortDescriptor(key: col.rawValue, ascending: state.ascending)
            if table.sortDescriptors.first?.key != desired.key
               || table.sortDescriptors.first?.ascending != desired.ascending {
                table.sortDescriptors = [desired]
            }
        }
        isInstallingColumns = false
        let ids: Set<Int> = state.selectionMode ? state.multiSelection
            : (state.selection.map { [$0] } ?? [])
        var indices: [Int] = []
        for (i, b) in state.books.enumerated() where ids.contains(b.id) { indices.append(i) }
        let set = IndexSet(indices)
        if table.selectedRowIndexes != set { table.selectRowIndexes(set, byExtendingSelection: false) }
    }

    @objc func handleDoubleClick(_ sender: Any?) {
        guard let table = tableView, table.clickedRow >= 0, table.clickedRow < state.books.count else { return }
        state.openViewer(book: state.books[table.clickedRow])
    }

    @objc func boundsDidChange(_ notification: Notification) {
        guard state.scrollMode == .infinite, let scroll = scrollView,
              let doc = scroll.documentView else { return }
        let visibleMaxY = scroll.contentView.bounds.maxY
        if visibleMaxY > doc.bounds.height - 400 {
            Task { await state.loadMore() }
        }
    }
}

extension RemoteBookTableCoordinator: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { state.books.count }
}

extension RemoteBookTableCoordinator: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < state.books.count else { return nil }
        let book = state.books[row]
        if col.identifier.rawValue == RemoteBookTableCoordinator.downloadColumnID {
            let downloaded = state.isDownloaded(book.id)
            let icon = AnyView(
                Image(systemName: downloaded ? "arrow.down.circle.fill" : "")
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .help(downloaded ? "オフライン保存済み" : "")
            )
            let id = col.identifier
            let hosting: NSHostingView<AnyView>
            if let reuse = tableView.makeView(withIdentifier: id, owner: nil) as? NSHostingView<AnyView> {
                hosting = reuse
            } else {
                hosting = NSHostingView(rootView: AnyView(EmptyView()))
                hosting.identifier = id
            }
            hosting.rootView = icon
            return hosting
        }
        guard let bookCol = BookColumn(rawValue: col.identifier.rawValue) else { return nil }
        let hosting: NSHostingView<AnyView>
        if let reuse = tableView.makeView(withIdentifier: col.identifier, owner: nil) as? NSHostingView<AnyView> {
            hosting = reuse
        } else {
            hosting = NSHostingView(rootView: AnyView(EmptyView()))
            hosting.identifier = col.identifier
        }
        hosting.rootView = AnyView(bookCellView(bookCol, provider: book, settings: settings))
        return hosting
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = tableView else { return }
        let sel = table.selectedRowIndexes
        if state.selectionMode {
            state.multiSelection = Set(sel.compactMap { $0 < state.books.count ? state.books[$0].id : nil })
        } else if let first = sel.first, first < state.books.count {
            let id = state.books[first].id
            if state.selection != id { Task { await state.selectBook(id) } }
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isInstallingColumns, let key = tableView.sortDescriptors.first?.key,
              let col = BookColumn(rawValue: key) else { return }
        Task { await state.applyHeaderSort(column: col) }
    }
}

extension RemoteBookTableCoordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === headerMenu {
            for item in menu.items {
                guard let col = item.representedObject as? BookColumn else { continue }
                item.title = settings.label(for: col)
                item.state = settings.listViewColumns.contains(col) ? .on : .off
            }
            return
        }
        menu.removeAllItems()
        menu.autoenablesItems = false
        guard let table = tableView, table.clickedRow >= 0, table.clickedRow < state.books.count else { return }
        let book = state.books[table.clickedRow]
        if !table.selectedRowIndexes.contains(table.clickedRow) {
            table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        }
        let openItem = NSMenuItem(title: String(localized: "ビューワで開く"),
                                  action: #selector(ctxOpen(_:)), keyEquivalent: "")
        openItem.target = self; openItem.representedObject = book.id
        menu.addItem(openItem)
        let dlTitle = state.isDownloaded(book.id) ? String(localized: "ダウンロード済み")
                                                  : String(localized: "ダウンロード")
        let dlItem = NSMenuItem(title: dlTitle, action: #selector(ctxDownload(_:)), keyEquivalent: "")
        dlItem.target = self; dlItem.representedObject = book.id
        dlItem.isEnabled = !state.isDownloaded(book.id)
        menu.addItem(dlItem)
    }

    @objc private func ctxOpen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int, let b = state.books.first(where: { $0.id == id }) else { return }
        state.openViewer(book: b)
    }
    @objc private func ctxDownload(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int, let b = state.books.first(where: { $0.id == id }) else { return }
        Task { await state.downloadBook(b) }
    }
}
