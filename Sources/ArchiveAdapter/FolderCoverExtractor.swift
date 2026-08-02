// SPDX-License-Identifier: MIT
import Foundation
import OSLog

/// Extracts the lexicographically first image file directly under the given folder URL.
/// Subdirectories are NOT walked.
public struct FolderCoverExtractor: CoverImageExtractor {
    // Phase 2.6b-2 T-C fixup: BookCategory.supportedExtensions に含まれる全画像拡張子に揃える。
    // heic/heif/tiff/tif/webp/avif は macOS NSImage で描画可能。
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp",
        "heic", "heif", "tiff", "tif", "avif"
    ]

    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "FolderCoverExtractor")

    public init() {}

    public func extractCoverImage(from url: URL) async throws -> Data {
        return try await extractCoverImage(from: url, preferredName: nil)
    }

    public func extractCoverImage(from url: URL, preferredName: String?) async throws -> Data {
        return try await Task.detached(priority: .userInitiated) {
            try Self.extract(from: url, preferredName: preferredName)
        }.value
    }

    /// フォルダは順次読みではないので打ち切りは起こらない（常に truncated: false）。
    public func listImageEntries(in url: URL) async throws -> ArchiveListing {
        return try await Task.detached(priority: .userInitiated) {
            ArchiveListing(names: try Self.listImageFiles(at: url)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }, truncated: false)
        }.value
    }

    public func countImageEntries(in url: URL) async throws -> Int {
        return try await Task.detached(priority: .userInitiated) {
            try Self.count(from: url)
        }.value
    }

    /// Phase 2.5i: フォルダ内の最初の PDF ファイル (natural sort 順) を Data として返す。
    /// PDF が無ければ nil。サブディレクトリは辿らない。
    /// 読み出し失敗時は OSLog warning を残して nil を返す (caller は「PDF なし」と区別できない)。
    public func extractFirstPDFData(in url: URL) async throws -> Data? {
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
                return nil
            }
            let pdf = entries
                .filter { $0.pathExtension.lowercased() == "pdf" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .first
            guard let pdf else { return nil }
            do {
                return try Data(contentsOf: pdf)
            } catch {
                Self.logger.warning("extractFirstPDFData: read failed for \(pdf.path, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    private static func count(from url: URL) throws -> Int {
        try listImageFiles(at: url).count
    }

    private static func listImageFiles(at url: URL) throws -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ArchiveAdapterError.archiveUnreadable(url, reason: "not a directory")
        }
        let names = try fm.contentsOfDirectory(atPath: url.path)
        return names.filter { name in
            let ext = (name as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { return false }
            // Exclude subdirectories
            var entryIsDir: ObjCBool = false
            let entryPath = url.appendingPathComponent(name).path
            guard fm.fileExists(atPath: entryPath, isDirectory: &entryIsDir),
                  !entryIsDir.boolValue else { return false }
            return true
        }
    }

    private static func extract(from url: URL, preferredName: String?) throws -> Data {
        let names = try listImageFiles(at: url)
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !sorted.isEmpty else { throw ArchiveAdapterError.noImageEntry(url) }
        let target: String
        if let pref = preferredName, sorted.contains(pref) {
            target = pref
        } else {
            target = sorted[0]
        }
        let fileURL = url.appendingPathComponent(target)
        let data = try Data(contentsOf: fileURL)
        if !data.isEmpty { return data }
        throw ArchiveAdapterError.noImageEntry(url)
    }
}
