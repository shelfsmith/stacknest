// SPDX-License-Identifier: MIT
import Foundation

/// G16 Codex High セキュリティ修正: `POST books/restore` がクライアント供給の `dto.path` を無条件に
/// 信用しないための土台。
///
/// 背景: `BookRestoreDTO.trashedPath` は既に廃止済み（TrashRestoreTracker 参照）だが、`dto.path`
/// 自体は残っており、restore はこれをそのまま DB へ書き戻す。この path はその後
/// `regenerateThumbnail`（アーカイブを開く）と、後続の `DELETE ?trash=true`（`trashFile` へ渡す
/// 移動元）の両方に流れる。admin が「未使用の id ＋ 任意の path」を持つ捏造 DTO を restore へ渡すと、
/// 復元 → trash 削除の 2 手でサーバーが読めるファイルを任意の場所へ移動できてしまう。
///
/// 対策: DELETE がある本を削除した直後（trash の有無に関わらず）、サーバー自身が読んだ
/// `row.path` を `(libraryUUID, bookID)` キーでこのアクターにのみ記録する。restore は
/// `take(uuid:bookID:)` で一度だけ引き出し、`dto.path` と記録済み値が一致する場合に限り
/// その path を全面的に信頼する。記録が無い（サーバー再起動・別セッション・そもそも
/// この id を削除したことが無い＝捏造）場合は、restore 側がライブラリの許可ルート
/// （監視フォルダ／バンドルツリー／現存する他本のディレクトリ）による代替検証にフォールバックする。
actor DeletedBookPathTracker {
    private struct Key: Hashable {
        let libraryUUID: String
        let bookID: Int
    }

    private var entries: [Key: String] = [:]

    /// DELETE libraries/:lib/books/:id が本を削除した直後に呼ぶ（trash の有無に関わらず）。
    func record(uuid: String, bookID: Int, path: String) {
        entries[Key(libraryUUID: uuid, bookID: bookID)] = path
    }

    /// restore の path 検証用に、記録があれば削除せず返す。実際の consume は
    /// restoreBook 成功後に `take` で行う（衝突で restoreBook が throw した場合に記録を
    /// 失わないため＝再試行で正規 path を保持。trashTracker が成功後に take するのと同形）。
    func peek(uuid: String, bookID: Int) -> String? {
        entries[Key(libraryUUID: uuid, bookID: bookID)]
    }

    /// restoreBook 成功後に呼ぶ。記録があれば返しつつ削除する（一度きり・再利用/使い回しを防ぐ）。
    @discardableResult
    func take(uuid: String, bookID: Int) -> String? {
        let key = Key(libraryUUID: uuid, bookID: bookID)
        guard let value = entries[key] else { return nil }
        entries.removeValue(forKey: key)
        return value
    }
}
