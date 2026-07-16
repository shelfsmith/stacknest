// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

/// 空欄の series/volume を title/filename から推測して埋めるバッチ。ローカル App と
/// リモートサーバの双方が使う共有コア（AppState.recomputeMetadataFromFilenames の抽出）。
public enum MetadataCompletion {
    /// 空欄 series/volume を埋めるための patch 群を計算する（DB は変更しない・undo 用にも使える）。
    public static func missingSeriesVolumePatches(in db: Database) throws -> [(bookID: Int, patch: BookPatch)] {
        let all = try db.fetchAllBooks()
        var patches: [(bookID: Int, patch: BookPatch)] = []
        for book in all {
            let filename = book.path.map { ($0 as NSString).lastPathComponent }
            let parsed = FilenameParser.parse(title: book.title, filename: filename)
            var patch = BookPatch()
            var hasChange = false
            if (book.series == nil || book.series?.isEmpty == true), let s = parsed.series {
                patch.series = s; hasChange = true
            }
            if book.volume == nil, let v = parsed.volume {
                patch.volume = v; hasChange = true
            }
            if hasChange { patches.append((bookID: book.id, patch: patch)) }
        }
        return patches
    }

    /// 上記 patch を DB へ直接適用する（サーバ用・undo 登録なし）。progress(done,total)・isCancelled 対応。
    /// isCancelled は actor-isolated なキャンセル状態（サーバのジョブレジストリ）を読めるよう async。
    /// 更新件数を返す。
    @discardableResult
    public static func fillMissingSeriesVolume(
        in db: Database,
        progress: (Int, Int) -> Void = { _, _ in },
        isCancelled: () async -> Bool = { false }
    ) async throws -> Int {
        let patches = try missingSeriesVolumePatches(in: db)
        let total = patches.count
        var done = 0
        for (bookID, patch) in patches {
            if await isCancelled() { break }
            try db.updateBook(id: bookID, patch: patch)
            done += 1
            progress(done, total)
        }
        return done
    }
}
