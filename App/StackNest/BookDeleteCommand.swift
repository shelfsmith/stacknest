// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import AppCore
import LibraryStore
import OSLog

@MainActor
public enum BookDeleteCommand {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "BookDeleteCommand")

    /// FX7: ⌫ / ⌘⌫ の破壊操作モード。
    enum DeleteMode {
        case library  // ⌫  : DB only (Stackroom 仕様)
        case trash    // ⌘⌫ : ファイルをゴミ箱へ + DB 削除
    }

    /// Removes books from DB only (Stackroom 仕様).
    /// Shows a confirmation dialog unless AppPreferences.confirmDeleteFromLibrary == false.
    /// "今後表示しない" suppression checkbox updates AppPreferences directly.
    /// Also cleans up bundle/Thumbnails/<bookID>/.
    ///
    /// When `appState` and `undoManager` are provided, the delete is routed through
    /// `AppState.deleteBooksFromLibrary` so it becomes Undo-able via ⌘Z.
    /// Thumbnail cleanup still runs after the undoable delete.
    // Note: appState parameter uses internal AppState type, so this method is internal.
    // All call sites are within the same module (StackNest app target).
    static func deleteFromLibrary(
        bookIDs: [Int],
        database: Database,
        bundleURL: URL,
        appState: AppState? = nil,
        undoManager: UndoManager? = nil
    ) {
        if AppPreferences.confirmDeleteFromLibrary {
            let alert = NSAlert()
            alert.messageText = "選択した \(bookIDs.count) 件をライブラリから削除しますか?"
            alert.informativeText = "ファイル本体は保持されます。"
            let delBtn = alert.addButton(withTitle: "削除")
            delBtn.hasDestructiveAction = true
            alert.addButton(withTitle: "キャンセル")

            let checkbox = NSButton(checkboxWithTitle: "今後この確認を表示しない", target: nil, action: nil)
            checkbox.state = .off
            alert.accessoryView = checkbox

            let response = alert.runModal()
            if response != .alertFirstButtonReturn {
                return  // cancelled
            }
            if checkbox.state == .on {
                AppPreferences.confirmDeleteFromLibrary = false
            }
        }

        performDeleteFromLibrary(
            bookIDs: bookIDs,
            database: database,
            bundleURL: bundleURL,
            appState: appState,
            undoManager: undoManager
        )
    }

    /// 確認なしでライブラリ削除を実行する実体。
    /// 2択パス (deleteFromLibrary, 確認後) と 3択パス (runScopeAwareDelete) の双方から呼ぶ。
    /// 確認ダイアログは呼び出し側の責務 — ここでは二重確認しない。
    private static func performDeleteFromLibrary(
        bookIDs: [Int],
        database: Database,
        bundleURL: URL,
        appState: AppState?,
        undoManager: UndoManager?
    ) {
        let thumbnailsDir = bundleURL.appendingPathComponent("Thumbnails")

        if let appState = appState {
            // Undo-aware path: route through UndoableCommand
            do {
                try appState.deleteBooksFromLibrary(bookIDs: bookIDs, undoManager: undoManager)
            } catch {
                logger.warning("deleteBooksFromLibrary failed: \(error.localizedDescription)")
            }
            // Thumbnail cleanup (not Undo-able by design — matches legacy behaviour).
            // Purge in-memory NSCache after disk removal so stale thumbnails cannot
            // survive a delete → re-add round-trip via cache hit.
            Task {
                await appState.thumbnailLoader?.purge()
            }
            for id in bookIDs {
                let bookDir = thumbnailsDir.appendingPathComponent(String(id))
                do {
                    try FileManager.default.removeItem(at: bookDir)
                    logger.info("Thumbnails dir removed: \(bookDir.path)")
                } catch {
                    logger.warning("Thumbnails dir removal failed for book \(id): \(error.localizedDescription)")
                }
            }
        } else {
            // Legacy path: direct DB mutation (no Undo support)
            for id in bookIDs {
                do {
                    try database.deleteBook(id: id)
                    let bookDir = thumbnailsDir.appendingPathComponent(String(id))
                    do {
                        try FileManager.default.removeItem(at: bookDir)
                        logger.info("Thumbnails dir removed: \(bookDir.path)")
                    } catch {
                        logger.warning("Thumbnails dir removal failed for book \(id): \(error.localizedDescription)")
                    }
                } catch {
                    logger.warning("Failed to delete book \(id): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Moves the book files to Trash, then deletes from DB.
    /// Shows a confirmation dialog before any action.
    /// Returns the IDs that were successfully removed.
    @discardableResult
    public static func moveToTrash(
        books: [(id: Int, url: URL)],
        database: Database,
        bundleURL: URL
    ) -> [Int] {
        let alert = NSAlert()
        alert.messageText = "選択した \(books.count) 件の本のファイルをゴミ箱に移動しますか?"
        alert.informativeText = "ゴミ箱から復元できますが、ライブラリの記録も削除されます。"
        alert.addButton(withTitle: "ゴミ箱に移動").hasDestructiveAction = true
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() != .alertFirstButtonReturn {
            return []
        }
        return performMoveToTrash(books: books, database: database, bundleURL: bundleURL)
    }

    /// 確認なしでゴミ箱移動 + DB 削除を実行する実体。
    /// 2択パス (moveToTrash, 確認後) と 3択パス (runScopeAwareDelete) の双方から呼ぶ。
    /// 確認ダイアログは呼び出し側の責務 — ここでは二重確認しない。
    @discardableResult
    private static func performMoveToTrash(
        books: [(id: Int, url: URL)],
        database: Database,
        bundleURL: URL
    ) -> [Int] {
        var succeeded: [Int] = []
        let thumbnailsDir = bundleURL.appendingPathComponent("Thumbnails")
        for (id, url) in books {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                try database.deleteBook(id: id)
                let bookDir = thumbnailsDir.appendingPathComponent(String(id))
                try? FileManager.default.removeItem(at: bookDir)
                succeeded.append(id)
            } catch {
                let errAlert = NSAlert()
                errAlert.messageText = "\(url.lastPathComponent) をゴミ箱に移動できませんでした"
                errAlert.informativeText = error.localizedDescription
                errAlert.runModal()
            }
        }
        return succeeded
    }

    /// FX7: scope を見て削除ダイアログを出す。
    /// `appState.removableShelfID != nil`（お気に入り / 手動シェルフ表示中）なら 3択ダイアログ、
    /// nil（スマートシェルフ / ライブラリ / 最近）なら従来の 2択パスへ委譲する。
    ///
    /// 3択のボタン順 → 戻り値 → アクションの対応:
    ///   1st = removableShelfRemoveButtonTitle  → alertFirstButtonReturn  → シェルフから外す（非破壊・デフォルト/Return）
    ///   2nd = "ライブラリから削除" / "ゴミ箱に移動" → alertSecondButtonReturn → 破壊的削除を即実行（確認は出さない）
    ///   3rd = "キャンセル"                       → alertThirdButtonReturn  → no-op（Esc も割当）
    ///
    /// 破壊的ブランチは performDeleteFromLibrary / performMoveToTrash（確認なしの実体）を呼ぶため、
    /// 二重確認は発生しない。また 3択は「今後表示しない」抑制を一切尊重せず、シェルフ表示中は常に表示する
    /// （シェルフ表示からのサイレント DB 削除は危険なため）。
    static func runScopeAwareDelete(
        mode: DeleteMode,
        appState: AppState,
        database: Database,
        bundleURL: URL,
        undoManager: UndoManager? = nil
    ) {
        let bookIDs = Array(appState.selectedBookIDs)
        guard !bookIDs.isEmpty else { return }

        // スマートシェルフ / ライブラリ / 最近 → 従来 2択へ委譲。
        guard appState.removableShelfID != nil else {
            switch mode {
            case .library:
                deleteFromLibrary(
                    bookIDs: bookIDs,
                    database: database,
                    bundleURL: bundleURL,
                    appState: appState,
                    undoManager: undoManager
                )
            case .trash:
                let books = appState.displayedSelectedBooks.compactMap { b -> (id: Int, url: URL)? in
                    guard let path = b.path, !path.isEmpty else { return nil }
                    return (id: b.id, url: URL(fileURLWithPath: path))
                }
                guard !books.isEmpty else { return }
                let removed = moveToTrash(books: books, database: database, bundleURL: bundleURL)
                if !removed.isEmpty {
                    do { try appState.refreshDisplayedBooks() }
                    catch { appState.error = .unexpected(error) }
                }
            }
            return
        }

        // お気に入り / 手動シェルフ → 3択ダイアログ。
        let count = bookIDs.count
        let alert = NSAlert()
        alert.messageText = "選択した \(count) 件をどうしますか?"
        switch mode {
        case .library:
            alert.informativeText = "「\(appState.removableShelfRemoveButtonTitle)」はこのシェルフから外すだけで、ライブラリには残ります。「ライブラリから削除」はライブラリの記録を削除します（ファイル本体は保持されます）。"
        case .trash:
            alert.informativeText = "「\(appState.removableShelfRemoveButtonTitle)」はこのシェルフから外すだけで、ライブラリには残ります。「ゴミ箱に移動」はファイルをゴミ箱へ移し、ライブラリの記録も削除します。"
        }

        // 1st = 非破壊（デフォルト = Return）
        alert.addButton(withTitle: appState.removableShelfRemoveButtonTitle)
        // 2nd = 破壊的
        let destructive = alert.addButton(withTitle: mode == .library ? "ライブラリから削除" : "ゴミ箱に移動")
        destructive.hasDestructiveAction = true
        // 3rd = キャンセル（Esc）
        let cancel = alert.addButton(withTitle: "キャンセル")
        cancel.keyEquivalent = "\u{1b}"  // Esc

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // 非破壊: シェルフから外す
            appState.removeSelectedBooksFromRemovableShelf()
        case .alertSecondButtonReturn:
            // 破壊的: 確認なしの実体を直接呼ぶ（二重確認しない）
            switch mode {
            case .library:
                performDeleteFromLibrary(
                    bookIDs: bookIDs,
                    database: database,
                    bundleURL: bundleURL,
                    appState: appState,
                    undoManager: undoManager
                )
            case .trash:
                let books = appState.displayedSelectedBooks.compactMap { b -> (id: Int, url: URL)? in
                    guard let path = b.path, !path.isEmpty else { return nil }
                    return (id: b.id, url: URL(fileURLWithPath: path))
                }
                guard !books.isEmpty else { return }
                let removed = performMoveToTrash(books: books, database: database, bundleURL: bundleURL)
                if !removed.isEmpty {
                    do { try appState.refreshDisplayedBooks() }
                    catch { appState.error = .unexpected(error) }
                }
            }
        default:
            break  // キャンセル / Esc → no-op
        }
    }
}
