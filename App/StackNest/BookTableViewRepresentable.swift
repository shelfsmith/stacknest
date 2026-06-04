// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import AppCore

/// NSTableView subclass that defers Coordinator.syncFromAppState calls until
/// super.mouseDown returns.
///
/// Without this gating, deferred-commit Tasks scheduled during memo/tag focus
/// loss can fire INSIDE NSTableView's mouseDown tracking loop. Their cascade
/// (applyPatch → refreshDisplayedBooks → updateNSView → syncFromAppState →
/// table.selectRowIndexes) reverts the in-progress click selection, so the
/// click ends up resolving to the original row and `tableViewSelectionDidChange`
/// never fires. Phase 2.4a-table-fix R5 (#17).
final class GatedTableView: NSTableView {
    /// True while AppKit is processing a mouse click (between mouseDown enter
    /// and super.mouseDown returning). Coordinator.syncFromAppState consults
    /// this and buffers its work via `pendingPostClickSync` instead of mutating
    /// table state mid-click.
    var isClickInProgress = false

    /// Closure scheduled by syncFromAppState when called during a click;
    /// runs once super.mouseDown returns.
    var pendingPostClickSync: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isClickInProgress = true
        super.mouseDown(with: event)
        isClickInProgress = false
        let pending = pendingPostClickSync
        pendingPostClickSync = nil
        pending?()
    }

    /// Right-click in empty area (below all rows) → show sort-only menu.
    /// Right-click on a row → delegate to the normal NSMenu (via super / NSTableView default).
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row < 0 {
            // Empty area: show sort submenu via coordinator
            return (delegate as? BookTableCoordinator)?.makeEmptyAreaMenu()
        }
        return super.menu(for: event)
    }

    /// Delete key handler for BookDeleteCommand.
    /// ⌫         → deleteFromLibrary (DB only, no dialog)
    /// ⌘⌫        → moveToTrash (confirmation dialog, then file + DB)
    /// Phase 2.5k T3rev3: ⌘+↑ / Home → 先頭、⌘+↓ / End → 末尾、PageUp/Down → 1 viewport 移動。
    override func keyDown(with event: NSEvent) {
        let isDelete = event.keyCode == 51
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // Phase 2.5k T3rev3: 先頭/末尾/Page を grid と統一実装
        let isHome = event.keyCode == 115
        let isEnd = event.keyCode == 119
        let isPageUp = event.keyCode == 116
        let isPageDown = event.keyCode == 121
        let isUpArrow = event.keyCode == 126
        let isDownArrow = event.keyCode == 125
        let isCommand = event.modifierFlags.contains(.command)

        guard let coordinator = delegate as? BookTableCoordinator else {
            super.keyDown(with: event)
            return
        }

        if isDelete {
            if isCommand {
                coordinator.handleMoveToTrash()
            } else {
                coordinator.handleDeleteFromLibrary()
            }
            return
        }
        if isReturn {
            coordinator.handleOpenSelected()
            return
        }
        if isHome || (isCommand && isUpArrow) {
            coordinator.handleSelectFirst()
            return
        }
        if isEnd || (isCommand && isDownArrow) {
            coordinator.handleSelectLast()
            return
        }
        if isPageUp {
            coordinator.handlePageUp()
            return
        }
        if isPageDown {
            coordinator.handlePageDown()
            return
        }
        if isCommand && (event.keyCode == 123 || event.keyCode == 124) {
            // ⌘+← (123) / ⌘+→ (124) は no-op だが消費
            return
        }
        super.keyDown(with: event)
    }
}

/// AppKit NSTableView wrapped as SwiftUI view. Replaces SwiftUI `Table` to avoid
/// the macOS Tahoe SwiftUI Table reentrancy bug that causes a hard freeze on
/// 10K-row datasets. Cell content is rendered by SwiftUI inside NSHostingView,
/// preserving Phase 2.4a UI conventions.
struct BookTableViewRepresentable: NSViewRepresentable {
    @Bindable var appState: AppState
    @Bindable var settings: LibrarySettings

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let table = GatedTableView()

        // Configuration
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.rowSizeStyle = .default

        // FX3 A5: list view を drag source 化 (drag-OUT のみ)。
        // pasteboardWriterForRow が NSPasteboardItem(.string) を返し、
        // sidebar shelf 行の .dropDestination(for: String.self) が受け取る。
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.doubleAction = #selector(BookTableCoordinator.handleDoubleClick(_:))
        table.target = context.coordinator

        context.coordinator.tableView = table
        context.coordinator.installColumns(in: table)

        // Context menu (Task 8 で動的に項目を入れる)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        // Column reorder (Task 9 で columnDidMove ハンドラを実装)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(BookTableCoordinator.columnDidMove(_:)),
            name: NSTableView.columnDidMoveNotification,
            object: table
        )

        // Column resize persistence (Fix K)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(BookTableCoordinator.handleColumnResize(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: table
        )

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.appState = appState
        coord.settings = settings
        coord.syncFromAppState()
    }

    func makeCoordinator() -> BookTableCoordinator {
        BookTableCoordinator(appState: appState, settings: settings)
    }
}
