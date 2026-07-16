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
    ///
    /// Codex review Important #2: 対象 bookID の候補一覧は事前スナップショットで求めるが、
    /// 各本への patch は適用直前に DB から再取得した最新状態から再計算する。`await isCancelled()`
    /// でのサスペンション中に別クライアントが series/volume を編集した場合、その編集を
    /// 古い推測値で上書きしないため（空欄のときだけ埋める、というルールを最新状態に対して適用）。
    @discardableResult
    public static func fillMissingSeriesVolume(
        in db: Database,
        progress: (Int, Int) -> Void = { _, _ in },
        isCancelled: () async -> Bool = { false }
    ) async throws -> Int {
        let candidates = try missingSeriesVolumePatches(in: db)
        let total = candidates.count
        var processed = 0
        var applied = 0
        for (bookID, _) in candidates {
            if await isCancelled() { break }
            defer { processed += 1; progress(processed, total) }
            guard let fresh = try db.fetchBook(id: bookID) else { continue }
            let filename = fresh.path.map { ($0 as NSString).lastPathComponent }
            let parsed = FilenameParser.parse(title: fresh.title, filename: filename)
            var patch = BookPatch()
            var hasChange = false
            if (fresh.series == nil || fresh.series?.isEmpty == true), let s = parsed.series {
                patch.series = s; hasChange = true
            }
            if fresh.volume == nil, let v = parsed.volume {
                patch.volume = v; hasChange = true
            }
            guard hasChange else { continue }
            try db.updateBook(id: bookID, patch: patch)
            applied += 1
        }
        return applied
    }
}
