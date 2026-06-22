// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

/// 4.2c-9: メニューコマンドが操作する「アクティブなブラウザ」の抽象。
/// ローカル(AppState)/リモート(RemoteCommandTarget)が conform し focusedSceneValue で提供する。
/// capability で、削除等のリモート無効化（canManageFiles）・設定の RW 限定（canEditMeta）・
/// レートの R 許可（canRate）を表現する。
@MainActor protocol BrowserCommandTarget {
    func toggleViewMode()          // グリッド⇔リスト
    func cycleTopPane()            // ブラウズ/スタンプ/隠す
    func setRating(_ stars: Int)   // 選択本のレート（0–5）
    func openSettings()            // ライブラリ設定（シート表示）
    var canEditMeta: Bool { get }     // 設定の有効条件（リモート R では false ＝ RW のみ）
    var canManageFiles: Bool { get }  // 削除/リネーム/移動等（ローカル=true / リモート=false）
    var canRate: Bool { get }         // レート（ローカル/リモートとも true・R 可）
}

private struct BrowserCommandTargetKey: FocusedValueKey {
    typealias Value = any BrowserCommandTarget
}
extension FocusedValues {
    var browserCommandTarget: (any BrowserCommandTarget)? {
        get { self[BrowserCommandTargetKey.self] }
        set { self[BrowserCommandTargetKey.self] = newValue }
    }
}

/// リモートウィンドウのメニューターゲット（state + per-window settings）。
@MainActor struct RemoteCommandTarget: BrowserCommandTarget {
    let state: RemoteLibraryState
    let settings: LibrarySettings

    func toggleViewMode() { state.isGrid.toggle() }
    func cycleTopPane() { settings.cycleTopPaneMode() }
    func setRating(_ stars: Int) { state.setRatingForSelection(stars) }
    func openSettings() { NotificationCenter.default.post(name: .openRemoteLibrarySettings, object: nil) }
    var canEditMeta: Bool { state.canEditServer }
    var canManageFiles: Bool { false }   // 将来ヘッドレス庫のリモート管理で true にする余地を残す
    var canRate: Bool { true }
}

extension Notification.Name {
    /// 4.2c-9: リモートウィンドウで「ライブラリ設定」を開く通知。
    static let openRemoteLibrarySettings = Notification.Name("stacknest.openRemoteLibrarySettings")
}
