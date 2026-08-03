// SPDX-License-Identifier: MIT
import Foundation

/// Extracts a representative cover image from a book file (zip / cbz / folder / etc).
/// Used by Phase 2.5b's add flow; Phase 2.5a only defines the protocol skeleton.
public protocol CoverImageExtractor: Sendable {
    /// The file URL (zip, cbz, folder, etc) to extract a cover from.
    /// Returns image data (JPEG or PNG); caller is responsible for re-encoding to thumbnail.
    func extractCoverImage(from url: URL) async throws -> Data

    /// Extracts image data for the specified entry name (preferredName).
    /// If preferredName is nil or the entry is not found, falls back to the first entry
    /// in natural sort order (graceful degradation — never throws due to missing preferred name).
    func extractCoverImage(from url: URL, preferredName: String?) async throws -> Data

    /// Returns the list of image entry names inside the archive, sorted in natural order.
    /// 破損等で列挙が打ち切られた場合は `truncated == true` で、**読めた分だけ**を返す。
    func listImageEntries(in url: URL) async throws -> ArchiveListing

    /// Counts the number of image entries inside the archive or folder.
    /// 破損等で計数が途中で打ち切られた場合は `truncated == true` で、**数えられた分だけ**を返す
    /// （`listImageEntries` の `ArchiveListing.truncated` と同じ意味論。G26 Import gate fixup）。
    /// Returns count 0 / truncated false by default; conformers override to provide a real count.
    func countImageEntries(in url: URL) async throws -> ArchiveEntryCount

    /// Phase 2.5i: アーカイブ / フォルダ内の **最初の PDF entry** の Data を返す。
    /// PDF が無ければ nil。画像 0 件時のフォールバック cover 用。
    ///
    /// nil = "PDF entry が存在しない" を意味する (extractCoverImage が throws する no-image case と
    /// 対照的)。read 失敗時は実装が log を残しつつ nil を返すため、caller は「PDF なし」と
    /// 「読み出し失敗」を区別できない — これは fallback 用 API として意図的な設計。
    func extractFirstPDFData(in url: URL) async throws -> Data?
}

public extension CoverImageExtractor {
    func countImageEntries(in url: URL) async throws -> ArchiveEntryCount { ArchiveEntryCount(count: 0, truncated: false) }

    /// Default: PDF 非対応 (`nil`)。LibarchiveCoverExtractor / FolderCoverExtractor で override する。
    func extractFirstPDFData(in url: URL) async throws -> Data? { nil }

    /// Default: returns empty listing (conformers that don't implement this will report no entries).
    func listImageEntries(in url: URL) async throws -> ArchiveListing {
        ArchiveListing(names: [], truncated: false)
    }

    /// Default: forwards to extractCoverImage(from:) ignoring preferredName — backward compat.
    func extractCoverImage(from url: URL, preferredName: String?) async throws -> Data {
        try await extractCoverImage(from: url)
    }
}

public enum ArchiveAdapterError: Error, Equatable, Sendable {
    /// Archive could not be opened (corrupt, unsupported format, permissions).
    case archiveUnreadable(URL, reason: String)
    /// Archive opened but no image entries found.
    case noImageEntry(URL)
}
