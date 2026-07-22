// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// 4.2c-9: ローカルライブラリウィンドウのメニューターゲット。
/// 削除等のファイル操作はローカルで有効（canManageFiles=true）、設定/レートも有効。
extension AppState: BrowserCommandTarget {
    func toggleViewMode() { viewMode = (viewMode == .grid ? .list : .grid) }
    func cycleTopPane() { librarySettings?.cycleTopPaneMode() }
    func setRating(_ stars: Int) { setRatingForSelected(stars, undoManager: undoManager) }
    func toggleUnread() { toggleUnreadForSelected(undoManager: undoManager) }
    func openSettings() { NotificationCenter.default.post(name: .openLibrarySettings, object: nil) }
    var canEditMeta: Bool { true }
    var canManageFiles: Bool { true }
    var canManageLocalFiles: Bool { true }
    var canRate: Bool { true }
    var canMarkUnread: Bool { true }
    var librarySettingsForColumns: LibrarySettings? { librarySettings }
}
