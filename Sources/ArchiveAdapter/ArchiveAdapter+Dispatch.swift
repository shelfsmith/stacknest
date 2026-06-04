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
        case "zip", "cbz", "cbr", "rar", "7z", "cb7":
            return LibarchiveCoverExtractor()
        default:
            return nil
        }
    }
}
