// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import AppCore
import LibraryServerAPI

/// Return/Enter で選択本を開くための NSTableView サブクラス。
final class RemoteKeyTableView: NSTableView {
    var onReturnKey: (() -> Void)?
    /// クリック処理中ガード（ローカル GatedTableView と同方針）。DL 中など updateNSView が高頻度で
    /// 走るとき、クリック追跡中に syncFromState の reloadData/selectRowIndexes が割り込むと
    /// ユーザーの選択が即座に巻き戻る。mouseDown の間はテーブル変更をバッファして click 後に流す。
    var isClickInProgress = false
    var pendingPostClickSync: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isClickInProgress = true
        super.mouseDown(with: event)
        isClickInProgress = false
        let pending = pendingPostClickSync
        pendingPostClickSync = nil
        pending?()
    }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = Enter(テンキー)
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturnKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// リモートのリスト表示。ローカル NSTableView と同じ列モデル（BookColumn/LibrarySettings）と
/// セル描画（bookCellView）を使い、配線先を RemoteLibraryState にしたリモート専用版。
struct RemoteBookTableViewRepresentable: NSViewRepresentable {
    @Bindable var state: RemoteLibraryState
    @Bindable var settings: LibrarySettings

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let table = RemoteKeyTableView()
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
        table.onReturnKey = { [weak coordinator = context.coordinator] in
            coordinator?.handleOpenSelected()
        }
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
        _ = state.downloadProgress?.fraction
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
    /// syncFromState のプログラム的な reloadData/selectRowIndexes 中に発火する
    /// tableViewSelectionDidChange を無視するためのガード（ユーザー操作以外で multiSelection を壊さない）。
    private var isSyncingSelection = false
    private var lastBooksVersion = -1
    private var lastDownloadedVersion = -1
    private var lastProgressKey: String = ""

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
        // クリック処理中はテーブル状態（reloadData/selectRowIndexes）を触らない。触るとクリックが
        // 巻き戻る（DL 中の高頻度 updateNSView で「クリックしても即戻る」不具合の原因）。
        // mouseDown 完了後に 1 度だけ流す（ローカル GatedTableView と同方針）。
        if let keyTable = table as? RemoteKeyTableView, keyTable.isClickInProgress {
            keyTable.pendingPostClickSync = { [weak self] in self?.syncFromState() }
            return
        }
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        if state.booksVersion != lastBooksVersion || state.downloadedVersion != lastDownloadedVersion {
            lastBooksVersion = state.booksVersion
            lastDownloadedVersion = state.downloadedVersion
            table.reloadData()
        }
        let pk = state.downloadProgress.map { "\($0.bookID):\(Int($0.fraction * 20))" } ?? ""
        if pk != lastProgressKey {
            lastProgressKey = pk
            // v5 NG 根因修正: 進捗更新（5%刻み≒20回/件）ごとに全行 reloadData すると、
            // 5,000 件規模＋複数選択の再選択処理で MainActor が飽和し、×（中断）ボタンの
            // クリックが処理されなくなる。対象行の DL 列セルだけを部分再描画して負荷を激減させる。
            if let prog = state.downloadProgress,
               let row = state.books.firstIndex(where: { $0.id == prog.bookID }),
               let colIdx = table.tableColumns.firstIndex(where: {
                   $0.identifier.rawValue == Self.downloadColumnID }) {
                table.reloadData(forRowIndexes: IndexSet(integer: row),
                                 columnIndexes: IndexSet(integer: colIdx))
            }
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
        // 4.2c-3: native ⌘/Shift 複数選択。multiSelection を正とし、無ければ
        // 単一選択（state.selection）にフォールバックして行を選択し直す。
        let ids: Set<Int> = state.multiSelection.isEmpty
            ? (state.selection.map { [$0] } ?? [])
            : state.multiSelection
        var indices: [Int] = []
        for (i, b) in state.books.enumerated() where ids.contains(b.id) { indices.append(i) }
        let set = IndexSet(indices)
        if table.selectedRowIndexes != set { table.selectRowIndexes(set, byExtendingSelection: false) }
    }

    @objc func handleDoubleClick(_ sender: Any?) {
        guard let table = tableView, table.clickedRow >= 0, table.clickedRow < state.books.count else { return }
        state.openViewer(book: state.books[table.clickedRow])
    }

    /// Return キー: 選択中の先頭の本をビューワで開く（リモートビューワは 1 ウィンドウ運用のため先頭のみ）。
    @objc func handleOpenSelected() {
        guard let table = tableView,
              let idx = table.selectedRowIndexes.first,
              idx < state.books.count else { return }
        state.openViewer(book: state.books[idx])
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
            let prog = state.downloadProgress
            let cell: AnyView
            if let prog, prog.bookID == book.id {
                cell = AnyView(
                    ProgressView(value: prog.fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                )
            } else {
                cell = AnyView(
                    Image(systemName: downloaded ? "arrow.down.circle.fill" : "")
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .help(downloaded ? "オフライン保存済み" : ""))
            }
            let id = col.identifier
            let hosting: NSHostingView<AnyView>
            if let reuse = tableView.makeView(withIdentifier: id, owner: nil) as? NSHostingView<AnyView> {
                hosting = reuse
            } else {
                hosting = NSHostingView(rootView: AnyView(EmptyView()))
                hosting.identifier = id
            }
            hosting.rootView = cell
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
        guard !isSyncingSelection else { return }   // プログラム的変更は無視（ユーザー操作のみ反映）
        guard let table = tableView else { return }
        let sel = table.selectedRowIndexes
        // 4.2c-3: native ⌘/Shift 複数選択。選択された行集合をそのまま multiSelection に反映する。
        let ids = Set(sel.compactMap { $0 < state.books.count ? state.books[$0].id : nil })
        state.multiSelection = ids
        // 単一選択時のみ詳細ペインを更新する（複数選択中は詳細を切り替えない）。
        if ids.count == 1, let first = sel.first, first < state.books.count {
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
        // 4.2c-3 (D2b): 複数選択時は選択集合に対する「選択をダウンロード」。選択内に未 DL が
        // 1 件でもあれば有効化し、downloadSelected()（未 DL のみ DL）を呼ぶ。DL 済みが混在
        // していても disabled にしない（ツールバーのダウンロードボタンと挙動を揃える）。
        let selected = table.selectedRowIndexes
        if selected.count >= 2 {
            let selBooks = selected.compactMap { $0 < state.books.count ? state.books[$0] : nil }
            let anyNotDownloaded = selBooks.contains { !state.isDownloaded($0.id) }
            let dlItem = NSMenuItem(title: String(localized: "選択をダウンロード"),
                                    action: #selector(ctxDownloadSelected(_:)), keyEquivalent: "")
            dlItem.target = self
            dlItem.isEnabled = anyNotDownloaded
            menu.addItem(dlItem)
        } else {
            let dlTitle = state.isDownloaded(book.id) ? String(localized: "ダウンロード済み")
                                                      : String(localized: "ダウンロード")
            let dlItem = NSMenuItem(title: dlTitle, action: #selector(ctxDownload(_:)), keyEquivalent: "")
            dlItem.target = self; dlItem.representedObject = book.id
            dlItem.isEnabled = !state.isDownloaded(book.id)
            menu.addItem(dlItem)
        }
    }

    @objc private func ctxOpen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int, let b = state.books.first(where: { $0.id == id }) else { return }
        state.openViewer(book: b)
    }
    @objc private func ctxDownload(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int, let b = state.books.first(where: { $0.id == id }) else { return }
        Task { await state.downloadBook(b) }
    }
    /// 4.2c-3 (D2b): 複数選択に対する一括ダウンロード（未 DL のみ）。multiSelection を対象にする。
    /// v6 NG 修正: downloadSelected() 直呼びだと startBatchDownload() を通らずキャンセルトークンが
    /// 作られず、×（中断）が効かない（token=false）。必ず startBatchDownload() 経由で起動する。
    @objc private func ctxDownloadSelected(_ sender: NSMenuItem) {
        state.startBatchDownload()
    }
}
