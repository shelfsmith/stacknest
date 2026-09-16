// SPDX-License-Identifier: MIT
import Foundation

extension ArchiveAdapter {
    /// Returns the appropriate `CoverImageExtractor` for the given URL based on its file extension,
    /// or whether the URL points to a directory.
    /// Returns nil for unsupported types.
    public static func coverExtractor(for url: URL) -> CoverImageExtractor? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return FolderCoverExtractor()
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        // G54-S4: EPUB は zip なので libarchive がそのまま読める。中身は画像の拡張子で絞られる
        // （`LibarchiveCoverExtractor.imageExtensions`）ので、XHTML や CSS は候補に並ばない。
        // EPUB 専用の抽出器は作らない（取り込み側の `EPUBAdapter.reader` は別目的の別経路）。
        case "zip", "cbz", "cbr", "rar", "7z", "cb7", "epub":
            return LibarchiveCoverExtractor()
        default:
            return nil
        }
    }
}
