// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import AppCore

/// Return/Enter で選択本を開くための NSTableView サブクラス。
final class RemoteKeyTableView: NSTableView {
    var onReturnKey: (() -> Void)?
    /// Home/End/PageUp/PageDown での選択移動（ローカル list 相当）。
    var onNavKey: ((_ kind: NavKind) -> Void)?
    enum NavKind { case home, end, pageUp, pageDown }

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
        switch event.keyCode {
        case 36, 76:   // Return / テンキー Enter
            onReturnKey?()
        case 115: onNavKey?(.home)
        case 119: onNavKey?(.end)
        case 116: onNavKey?(.pageUp)
        case 121: onNavKey?(.pageDown)
        default:
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
        // Home/End/PageUp/PageDown での選択移動（ローカル list の
        // computeRowsPerPage/selectAndScrollTable 相当・list は columns=1）。
        table.onNavKey = { [weak table] kind in
            let books = state.books
            guard !books.isEmpty else { return }
            let cur = state.selection.flatMap { id in books.firstIndex(where: { $0.id == id }) } ?? 0
            let rowsPerPage: Int = {
                guard let table else { return 20 }
                let viewportHeight = table.enclosingScrollView?.documentVisibleRect.height ?? table.bounds.height
                let rowHeight = table.rowHeight + table.intercellSpacing.height
                guard rowHeight > 0, viewportHeight > 0 else { return 20 }
                return max(1, Int(viewportHeight / rowHeight))
            }()
            let t: Int?
            switch kind {
            case .home:     t = GridNavigator.firstIndex(total: books.count)
            case .end:      t = GridNavigator.lastIndex(total: books.count)
            case .pageUp:   t = GridNavigator.pageIndex(current: cur, total: books.count, columns: 1, rows: rowsPerPage, up: true)
            case .pageDown: t = GridNavigator.pageIndex(current: cur, total: books.count, columns: 1, rows: rowsPerPage, up: false)
            }
            guard let t else { return }
            // C2 fix: syncFromState は multiSelection 優先で行選択を復元するため選択集合も更新する
            // （selectBook＝state.selection だけだと非空 multiSelection に隠れてハイライトが動かない）。
            state.multiSelection = [books[t].id]
            // state.selectBook の反映（syncFromState）を待たず、その場でスクロール追従させる。
            table?.scrollRowToVisible(t)
            Task { await state.selectBook(books[t].id) }
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
        // 4.2c-8: ラベル override（サーバ同期・編集保存）変更時に再走させ、列ヘッダを更新する。
        _ = settings.remoteFieldLabelOverride
        _ = settings.remoteBookTypeLabelOverride
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
    /// G16 E1: state.listScrollResetVersion の直近反映値。ユーザー操作由来のリセット
    /// （filter/sort/sidebar/mode/search）でのみ増える版数を観測し、無限スクロール後の
    /// フィルタで件数が減った際にスクロール位置/選択が旧・空の末尾に取り残される不具合を防ぐ。
    private var lastScrollResetVersion = -1

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
        if let table = tableView {
            installColumns(in: table)
            // G44: ON にしたらその列が見える位置へ（ローカルと同じ判断を同じ関数で）。
            if let idx = ColumnRevealPolicy.indexToReveal(
                toggled: col,
                nowVisible: settings.listViewColumns.contains(col),
                columnIdentifiers: table.tableColumns.map { $0.identifier.rawValue }) {
                table.scrollColumnToVisible(idx)
            }
        }
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
        // G16 E1: ユーザー操作由来のリセット（reload(clearFirst: true)）のときだけ先頭へ戻す。
        // liveReload/loadMore/reload(clearFirst: false)（位置保持経路）では version が不変のため
        // ここには入らない。reloadData() の後に判定することで、行数はフィルタ後の件数を反映する。
        if state.listScrollResetVersion != lastScrollResetVersion {
            lastScrollResetVersion = state.listScrollResetVersion
            if table.numberOfRows > 0 {
                table.scrollRowToVisible(0)
            } else if let scroll = scrollView ?? table.enclosingScrollView {
                // G44 指摘A: y だけ 0 に戻し、x（水平スクロール位置）は保持する。
                // ここで x も 0 にすると、reload 中の空の間に列トグルの横スクロール（installColumns 側）が
                // 打ち消される（非空側の scrollRowToVisible(0) は水平位置を保持するため、2 分岐で挙動が揃う）。
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
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
        if current != visibleColumns {
            installColumns(in: table)
        } else {
            // 4.2c-8: 列セット不変でも列ヘッダのラベルを更新する（override 変更を反映・A1/B2）。
            for nsCol in table.tableColumns {
                if let col = BookColumn(rawValue: nsCol.identifier.rawValue) {
                    nsCol.title = settings.label(for: col)
                }
            }
        }
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

    /// Return キー: 選択中の先頭の本をビューアで開く（リモートビューアは 1 ウィンドウ運用のため先頭のみ）。
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
        guard let table = tableView, table.clickedRow >= 0, table.clickedRow < state.books.count else {
            // 空白（clickedRow < 0）右クリック: grid の空白右クリックと同じ「並び替え」submenu を出す。
            menu.addItem(buildSortMenuItem())
            return
        }
        let book = state.books[table.clickedRow]
        if !table.selectedRowIndexes.contains(table.clickedRow) {
            table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        }
        let openItem = NSMenuItem(title: String(localized: "ビューアで開く"),
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
        menu.addItem(NSMenuItem.separator())

        // レート submenu（0=レートなし, 1-5=★）。共有状態のため canEdit ゲート不要（ローカル同等）。
        let rateItem = NSMenuItem(title: String(localized: "レート"), action: nil, keyEquivalent: "")
        let rateSub = NSMenu()
        let noRate = NSMenuItem(title: String(localized: "レートなし"), action: #selector(ctxSetRating(_:)), keyEquivalent: "")
        noRate.target = self; noRate.representedObject = 0; rateSub.addItem(noRate)
        for s in 1...5 {
            let it = NSMenuItem(title: String(repeating: "★", count: s), action: #selector(ctxSetRating(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = s; rateSub.addItem(it)
        }
        rateItem.submenu = rateSub
        menu.addItem(rateItem)

        // 種類 submenu（0...5・カスタムラベル反映）。編集権限（canEdit）でゲート。
        if state.canEdit {
            let typeItem = NSMenuItem(title: String(localized: "種類"), action: nil, keyEquivalent: "")
            let typeSub = NSMenu()
            for t in 0...5 {
                let it = NSMenuItem(title: settings.bookTypeLabel(t), action: #selector(ctxSetBookType(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = t; typeSub.addItem(it)
            }
            typeItem.submenu = typeSub
            menu.addItem(typeItem)
        }

        // 未読チェック トグル。共有状態のため canEdit ゲート不要。
        let unread = NSMenuItem(title: String(localized: "未読チェック"), action: #selector(ctxToggleUnread(_:)), keyEquivalent: "")
        unread.target = self; menu.addItem(unread)

        // G12b-2 Task 4: お気に入り 追加/削除・シェルフに追加（edit 未満では出さない）。
        // シェルフに追加の対象は grid（RemoteLibraryView.rateTypeUnreadOpenMenu）と同じ判定
        // （スマートでなく、お気に入りでもない棚）。サーバはスマート棚も kind=="user" で発行するため
        // kind だけでは区別できず、isSmart を必ず併用する（スマート棚は membership 変更不可＝サーバ 409）。
        if state.canEdit {
            if state.favoritesShelfID != nil {
                // G14: 選択が全てお気に入りなら「削除」・else「追加」の単一動的トグル（ローカル同様）。
                let title = state.allSelectedAreFavorites
                    ? String(localized: "お気に入りから削除")
                    : String(localized: "お気に入りに追加")
                let fav = NSMenuItem(title: title, action: #selector(ctxToggleFavorite(_:)), keyEquivalent: "")
                fav.target = self
                fav.representedObject = !state.allSelectedAreFavorites   // add フラグ
                menu.addItem(fav)
            }
            let userShelves = state.shelves.filter { !$0.isSmart && $0.kind != "favorites" }
            if !userShelves.isEmpty {
                let addShelfItem = NSMenuItem(title: String(localized: "シェルフに追加"), action: nil, keyEquivalent: "")
                let addShelfSub = NSMenu()
                for shelf in userShelves {
                    let it = NSMenuItem(title: shelf.title, action: #selector(ctxAddToShelf(_:)), keyEquivalent: "")
                    it.target = self; it.representedObject = shelf.id  // Int64
                    addShelfSub.addItem(it)
                }
                addShelfItem.submenu = addShelfSub
                menu.addItem(addShelfItem)
            } else if state.shelves.isEmpty {
                // shelves 未ロード（RemoteLibraryView 側の .task がまだ完了していない等）。
                // この回では出さず、次回メニュー表示までにロードされるよう kick する。
                Task { await state.loadShelves() }
            }
        }

        // Phase C-②.1: 削除（admin のみ）。File メニュー/grid と同じ 2 コマンド。
        if state.canDelete {
            menu.addItem(NSMenuItem.separator())
            let delLib = NSMenuItem(title: String(localized: "ライブラリから削除"),
                                    action: #selector(ctxDeleteLibrary(_:)), keyEquivalent: "")
            delLib.target = self
            menu.addItem(delLib)
            let delTrash = NSMenuItem(title: String(localized: "ファイルをゴミ箱に移動…"),
                                      action: #selector(ctxDeleteTrash(_:)), keyEquivalent: "")
            delTrash.target = self
            menu.addItem(delTrash)
        }

        // 並び替え submenu（grid の sortMenu() と同じロジック・全列・現在の sort に ✓/↑↓）。
        menu.addItem(NSMenuItem.separator())
        menu.addItem(buildSortMenuItem())
    }

    /// 「並び替え」submenu を構築する（行右クリック末尾／空白右クリックの両方で使用）。
    /// grid（RemoteLibraryView.sortMenu()）と同じ state.sortKey/ascending トグルロジックを共有する。
    private func buildSortMenuItem() -> NSMenuItem {
        let sortItem = NSMenuItem(title: String(localized: "並び替え"), action: nil, keyEquivalent: "")
        let sortSub = NSMenu()
        for col in BookColumn.allCases {
            let key = col.serverSortKey
            let it = NSMenuItem(title: settings.label(for: col), action: #selector(ctxSetSort(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            if state.sortKey == key {
                it.image = NSImage(systemSymbolName: state.ascending ? "chevron.up" : "chevron.down",
                                   accessibilityDescription: nil)
            }
            sortSub.addItem(it)
        }
        sortItem.submenu = sortSub
        return sortItem
    }

    @objc private func ctxOpen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int, let b = state.books.first(where: { $0.id == id }) else { return }
        state.openViewer(book: b)
    }
    @objc private func ctxDownload(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int, let b = state.books.first(where: { $0.id == id }) else { return }
        // 4.2c-4: 単一 DL も一括と同じ進捗バー/×中断 UI を出す。
        state.startSingleDownload(b)
    }
    /// 4.2c-3 (D2b): 複数選択に対する一括ダウンロード（未 DL のみ）。multiSelection を対象にする。
    /// v6 NG 修正: downloadSelected() 直呼びだと startBatchDownload() を通らずキャンセルトークンが
    /// 作られず、×（中断）が効かない（token=false）。必ず startBatchDownload() 経由で起動する。
    @objc private func ctxDownloadSelected(_ sender: NSMenuItem) {
        state.startBatchDownload()
    }
    private func selectedBookIDs() -> Set<Int> {
        guard let table = tableView else { return [] }
        return Set(table.selectedRowIndexes.compactMap { $0 < state.books.count ? state.books[$0].id : nil })
    }
    /// Phase C-②.1: ライブラリから削除（DB のみ）。
    @objc private func ctxDeleteLibrary(_ sender: NSMenuItem) {
        RemoteDeleteCommand.confirmAndDelete(ids: selectedBookIDs(), state: state, trash: false)
    }
    /// Phase C-②.1: ゴミ箱に移動（ファイル＋DB）。
    @objc private func ctxDeleteTrash(_ sender: NSMenuItem) {
        RemoteDeleteCommand.confirmAndDelete(ids: selectedBookIDs(), state: state, trash: true)
    }
    @objc private func ctxSetRating(_ sender: NSMenuItem) {
        state.setRatingForSelection((sender.representedObject as? Int) ?? 0)
    }
    @objc private func ctxSetBookType(_ sender: NSMenuItem) {
        state.setBookTypeForSelection((sender.representedObject as? Int) ?? 0)
    }
    @objc private func ctxToggleUnread(_ sender: NSMenuItem) {
        state.toggleUnreadForSelection()
    }
    /// 選択集合の解決（multiSelection 優先・無ければ selection）。ctxSetRating 系と同じ方針。
    private func selectionIDsForMenu() -> Set<Int> {
        state.multiSelection.isEmpty ? Set(state.selection.map { [$0] } ?? []) : state.multiSelection
    }
    /// G12b-2 Task 4: お気に入り 追加(true)/削除(false)。representedObject に Bool。
    @objc private func ctxToggleFavorite(_ sender: NSMenuItem) {
        guard let add = sender.representedObject as? Bool else { return }
        let ids = selectionIDsForMenu()
        Task { await state.toggleFavorite(ids: ids, add: add) }
    }
    /// G12b-2 Task 4: シェルフに追加。representedObject に shelf id (Int64)。
    @objc private func ctxAddToShelf(_ sender: NSMenuItem) {
        guard let shelfID = sender.representedObject as? Int64 else { return }
        let ids = selectionIDsForMenu()
        Task { await state.addSelectionToShelf(shelfID, ids: ids) }
    }
    /// 「並び替え」submenu 項目のアクション（grid の sortMenu() と同じロジック）。
    @objc private func ctxSetSort(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if state.sortKey == key {
            state.ascending.toggle()
        } else {
            state.sortKey = key
            state.ascending = true
        }
        Task { await state.reload() }
    }
}
