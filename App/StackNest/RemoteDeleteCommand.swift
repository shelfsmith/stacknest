// SPDX-License-Identifier: MIT
import AppKit

/// Phase C-②.1: リモートRW の本削除（admin のみ）。ローカルと同じ 2 コマンド
/// （ライブラリから削除＝DB のみ・ファイル残す／ゴミ箱に移動＝ファイルも削除）に整合。
/// File メニュー・list（NSMenu）・grid（SwiftUI contextMenu）から共通で呼ぶ確認付きヘルパ。
@MainActor
enum RemoteDeleteCommand {
    /// trash=false: ライブラリから削除（DB のみ）。trash=true: ゴミ箱に移動（ファイル＋DB）。
    static func confirmAndDelete(ids: Set<Int>, state: RemoteLibraryState, trash: Bool) {
        guard state.canDelete, !ids.isEmpty else { return }
        let alert = NSAlert()
        if trash {
            alert.messageText = String(localized: "選択した \(ids.count) 件のファイルをゴミ箱に移動しますか?")
            alert.informativeText = String(localized: "ファイルを macOS のゴミ箱へ移し、ライブラリの記録も削除します。⌘Z でライブラリの記録とファイルを（ゴミ箱から）戻せます。")
            alert.addButton(withTitle: String(localized: "ゴミ箱に移動")).hasDestructiveAction = true
        } else {
            alert.messageText = String(localized: "選択した \(ids.count) 件をライブラリから削除しますか?")
            alert.informativeText = String(localized: "ライブラリの記録のみ削除します（ファイルは残ります）。⌘Z で取り消せます。")
            alert.addButton(withTitle: String(localized: "ライブラリから削除")).hasDestructiveAction = true
        }
        alert.addButton(withTitle: String(localized: "キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.startBatchDelete(ids: ids, trash: trash)
    }
}
