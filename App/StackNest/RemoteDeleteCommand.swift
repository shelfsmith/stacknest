// SPDX-License-Identifier: MIT
import AppKit

/// Phase C-②: リモートRW の本削除（admin のみ）。NSAlert で「ライブラリから削除(DBのみ)」/
/// 「ゴミ箱に移動(ファイル+DB)」/「キャンセル」の 3 択を出し、選択に応じて state.deleteBooks を起動する。
/// list（NSMenu coordinator）と grid（SwiftUI contextMenu）の双方から呼ぶ共有ヘルパ。
@MainActor
enum RemoteDeleteCommand {
    static func presentAndDelete(ids: Set<Int>, state: RemoteLibraryState) {
        guard state.canDelete, !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "選択した \(ids.count) 件を削除しますか?")
        alert.informativeText = String(localized: "「ゴミ箱に移動」はファイルも削除します（ゴミ箱から復元可）。「ライブラリから削除」は記録のみ削除しファイルは残します。\nこの操作は取り消せません。")
        alert.addButton(withTitle: String(localized: "ライブラリから削除"))   // .alertFirstButtonReturn
        let trashBtn = alert.addButton(withTitle: String(localized: "ゴミ箱に移動"))  // .alertSecondButtonReturn
        trashBtn.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "キャンセル"))           // .alertThirdButtonReturn
        let resp = alert.runModal()
        let trash: Bool
        switch resp {
        case .alertFirstButtonReturn: trash = false
        case .alertSecondButtonReturn: trash = true
        default: return   // キャンセル
        }
        Task { await state.deleteBooks(ids: ids, trash: trash) }
    }
}
