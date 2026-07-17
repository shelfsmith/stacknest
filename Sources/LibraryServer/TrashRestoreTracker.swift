// SPDX-License-Identifier: MIT
import Foundation

/// G16 A3 セキュリティ修正: trash-undo のファイル移動元/移動先パスをクライアントに委ねない。
///
/// 背景: 当初実装は DELETE ?trash=true の応答（BookRestoreDTO.trashedPath）にゴミ箱内パスを載せ、
/// restore がそれと dto.path（元パス）を使って `FileManager.moveItem` していた。admin 専用エンド
/// ポイントとはいえ、細工した admin クライアントが任意の trashedPath/path の組を送れば、サーバーが
/// アクセスできる任意ファイルを任意の空きパスへ移動できてしまう（Arbitrary File Move via
/// Client-Controlled Paths）。
///
/// 対策: DELETE がファイルをゴミ箱へ送った直後、サーバー自身が観測した
/// (trashedURL, originalPath) をこのアクター内にのみ記録する。restore はクライアントの
/// BookRestoreDTO の中身を一切見ず、`(libraryUUID, bookID)` をキーにこの記録だけを頼りにファイルを
/// 元へ戻す。記録が無ければ（サーバー再起動・DB-only 削除など）ファイル移動はスキップし、DB 行の
/// 復元だけが成立する（degraded-safe）。
actor TrashRestoreTracker {
    private struct Key: Hashable {
        let libraryUUID: String
        let bookID: Int
    }

    private var entries: [Key: (trashedURL: URL, originalPath: String)] = [:]

    /// DELETE ?trash=true がファイルをゴミ箱へ送った直後に呼ぶ。
    func record(uuid: String, bookID: Int, trashedURL: URL, originalPath: String) {
        entries[Key(libraryUUID: uuid, bookID: bookID)] = (trashedURL, originalPath)
    }

    /// restore が呼ぶ。記録があれば返しつつ削除する（一度きり・再利用/二重移動を防ぐ）。
    func take(uuid: String, bookID: Int) -> (trashedURL: URL, originalPath: String)? {
        let key = Key(libraryUUID: uuid, bookID: bookID)
        guard let value = entries[key] else { return nil }
        entries.removeValue(forKey: key)
        return value
    }
}
