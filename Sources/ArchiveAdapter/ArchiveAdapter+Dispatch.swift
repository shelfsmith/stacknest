// SPDX-License-Identifier: MIT
import Foundation

extension ArchiveAdapter {
    /// libarchive がそのまま読める zip 系アーカイブの拡張子。フォルダは別枠（isDirectory 判定）。
    /// `coverExtractor(for:)` と `importExtractor(for:)` の両方がこの集合を土台にする。
    private static let libarchiveExtensions: Set<String> = ["zip", "cbz", "cbr", "rar", "7z", "cb7"]

    /// **表紙候補を選ぶ用。** フォルダ・zip 系アーカイブに加え、EPUB（G54-S4 以降。将来 PDF も）のように
    /// 取り込み時は専用経路を持つが「中の画像を表紙として選び直したい」形式も対象にする
    /// （詳細ペインの「表紙を編集」・cover-candidates/entry-image API が使う）。
    /// Returns nil for unsupported types.
    public static func coverExtractor(for url: URL) -> CoverImageExtractor? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return FolderCoverExtractor()
        }
        let ext = url.pathExtension.lowercased()
        // G54-S4: EPUB は zip なので libarchive がそのまま読める。中身は画像の拡張子で絞られる
        // （`LibarchiveCoverExtractor.imageExtensions`）ので、XHTML や CSS は候補に並ばない。
        // EPUB 専用の抽出器は作らない（取り込み側の `EPUBAdapter.reader` は別目的の別経路）。
        if ext == "epub" || Self.libarchiveExtensions.contains(ext) {
            return LibarchiveCoverExtractor()
        }
        return nil
    }

    /// **取り込み（`BookImporter`）専用。** フォルダ・zip 系アーカイブのみを返す。
    /// EPUB・PDF は取り込み時にページ数・表紙を専用経路（`EPUBAdapter.reader` /
    /// `PDFBookContent`）で扱うため、ここでは汎用アーカイブとして扱わない —
    /// `coverExtractor(for:)` に epub/pdf を混ぜたまま取り込みロジックがそれを使うと、
    /// 専用経路が黙ってスキップされてページ数・表紙が壊れる
    /// （G54-S4 修正ラウンド1で EPUB 取り込みが実際にこれで壊れた）。
    /// Returns nil for unsupported types (呼び出し側が拡張子ごとの専用処理へフォールバックする)。
    public static func importExtractor(for url: URL) -> CoverImageExtractor? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return FolderCoverExtractor()
        }
        let ext = url.pathExtension.lowercased()
        guard Self.libarchiveExtensions.contains(ext) else { return nil }
        return LibarchiveCoverExtractor()
    }
}
