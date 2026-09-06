// SPDX-License-Identifier: MIT
import Foundation
import StackroomFormat

/// ディレクトリの実在確認。既定は `FileManager` だが、テストからは差し替え可能。
public typealias DirectoryExistsChecker = @Sendable (String) -> Bool

public protocol ProgressReporter: Sendable {
    func reportProgress(processed: Int, total: Int)
}

/// A closure that extracts series and volume from a title (and optional filename).
/// Mirrors `FilenameParser.parse(title:filename:)` but avoids a circular module dependency:
/// `LibraryStore` → `AppCore` would be circular since `AppCore` depends on `LibraryStore`.
/// The real `FilenameParser` is injected from `AppCore` or `StackroomImportCLI` at call site.
public typealias SeriesVolumeParser = @Sendable (String, String?) -> (series: String?, volume: Double?)

public struct LibraryImporter: Sendable {
    public let database: Database

    /// Optional parser for filling in series/volume when the XML record has nil values.
    /// When nil, series/volume remain as-is (preserves backward-compatible behaviour).
    public let seriesVolumeParser: SeriesVolumeParser?

    /// G49: `Path` 復元候補（フォルダ書籍の親ディレクトリ）が実在するかどうかの確認。
    /// 既定は実ファイルシステムを見る。テストからは init で差し替える。
    private let directoryExists: DirectoryExistsChecker

    public init(
        database: Database,
        seriesVolumeParser: SeriesVolumeParser? = nil,
        directoryExists: @escaping DirectoryExistsChecker = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    ) {
        self.database = database
        self.seriesVolumeParser = seriesVolumeParser
        self.directoryExists = directoryExists
    }

    public func run(
        document: LibraryDocument,
        sourceURL: URL = URL(fileURLWithPath: "/dev/null"),
        sourceMTime: Date = Date(),
        progress: ProgressReporter? = nil
    ) throws -> ImportSummary {
        var summary = ImportSummary()
        let started = Date()
        defer { summary.elapsed = Date().timeIntervalSince(started) }

        let total = document.books.count + document.anomalies.count
        var processed = 0
        var recoveredPathCount = 0

        // G49: Stackroom 自身のサムネイル置き場を、復元候補から除外するために先に求めておく。
        let stackroomThumbnailsRoot = inferThumbnailsDirectory(from: sourceURL)

        for (_, book) in document.books {
            let (finalBook, recovered) = recoveredBook(
                filledBook(book), stackroomThumbnailsRoot: stackroomThumbnailsRoot)
            if recovered { recoveredPathCount += 1 }
            try database.insertBook(finalBook)
            summary.imported += 1
            processed += 1
            progress?.reportProgress(processed: processed, total: total)
        }

        if recoveredPathCount > 0 {
            summary.warnings.append("Recovered path from the cover image path for \(recoveredPathCount) book(s)")
        }

        for anomaly in document.anomalies {
            summary.skipped.append(
                SkippedBook(id: anomalyID(anomaly), reason: anomaly.localizedDescription)
            )
            processed += 1
            progress?.reportProgress(processed: processed, total: total)
        }

        for anomaly in document.playlistAnomalies {
            summary.warnings.append(anomaly.localizedDescription)
        }

        let validBookIDs: Set<Int> = Set(document.books.values.map(\.id))
        for playlist in document.playlists {
            let originalCount = playlist.items.count
            let validItems = playlist.items.filter { validBookIDs.contains($0) }
            let orphanCount = originalCount - validItems.count
            if orphanCount > 0 {
                summary.warnings.append(
                    "Playlist '\(playlist.title)': \(orphanCount) orphan book reference(s) skipped"
                )
            }
            let filteredPlaylist = PlaylistRecord(
                title: playlist.title,
                type: playlist.type,
                icon: playlist.icon,
                itemView: playlist.itemView,
                toolTab: playlist.toolTab,
                items: validItems,
                conditions: playlist.conditions
            )
            try database.insertPlaylist(filteredPlaylist)
        }

        let meta = ImportMeta(
            schemaVersion: 2,
            importedAt: Date(),
            sourceXMLPath: sourceURL.path,
            sourceXMLMTime: sourceMTime,
            importerVersion: "0.3.0",
            bookCount: summary.imported,
            skippedCount: summary.skipped.count,
            notes: nil
        )
        try database.writeImportMeta(meta)

        return summary
    }

    /// Returns a copy of `book` with series/volume filled from the parser when the XML values are nil.
    /// XML-provided values (non-nil) are always preserved as-is.
    private func filledBook(_ book: BookRecord) -> BookRecord {
        guard let parser = seriesVolumeParser,
              book.series == nil || book.volume == nil else {
            return book
        }
        let parsed = parser(book.title, nil)
        let filledSeries = book.series ?? parsed.series
        let filledVolume = book.volume ?? parsed.volume
        guard filledSeries != book.series || filledVolume != book.volume else {
            return book
        }
        return BookRecord(
            id: book.id,
            title: book.title,
            author: book.author,
            genre: book.genre,
            path: book.path,
            coverImagePath: book.coverImagePath,
            coverImageName: book.coverImageName,
            dateAdded: book.dateAdded,
            playDate: book.playDate,
            bookType: book.bookType,
            fileType: book.fileType,
            pages: book.pages,
            myRate: book.myRate,
            unseen: book.unseen,
            keywordA: book.keywordA,
            keywordB: book.keywordB,
            keywordC: book.keywordC,
            neta: book.neta,
            series: filledSeries,
            volume: filledVolume
        )
    }

    /// G49: `Path` が欠落している本を `Cover Image Path` から復元する。
    /// フォルダ書籍の親ディレクトリ候補は、実在するときだけ採用する。
    /// 返り値の `Bool` は復元を行ったかどうか（warning の件数集計用）。
    ///
    /// `stackroomThumbnailsRoot` は Stackroom 自身のサムネイル置き場
    /// （`<xml-parent>/Stackroom Library/<book-id>/thumbnail.jpg`）。**そこは本の置き場ではない**のに
    /// 必ず実在するため、実在確認だけでは弾けない。表紙がキャッシュを指している本は復元しない。
    private func recoveredBook(
        _ book: BookRecord, stackroomThumbnailsRoot: String?
    ) -> (BookRecord, Bool) {
        let plan = StackroomPathRecovery.plan(
            path: book.path, coverImagePath: book.coverImagePath, fileType: book.fileType)
        switch plan {
        case .keep, .unrecoverable:
            return (book, false)
        case .useCoverPath(let path):
            guard !isInsideStackroomCache(path, root: stackroomThumbnailsRoot) else { return (book, false) }
            return (withPath(path, of: book), true)
        case .useCoverParentDirectory(let directory):
            guard !isInsideStackroomCache(directory, root: stackroomThumbnailsRoot) else { return (book, false) }
            guard directoryExists(directory) else { return (book, false) }
            return (withPath(directory, of: book), true)
        }
    }

    /// 候補が Stackroom のサムネイルキャッシュの中か（キャッシュ自身も含む）。
    private func isInsideStackroomCache(_ candidate: String, root: String?) -> Bool {
        guard let root else { return false }
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private func withPath(_ path: String, of book: BookRecord) -> BookRecord {
        BookRecord(
            id: book.id,
            title: book.title,
            author: book.author,
            genre: book.genre,
            path: path,
            coverImagePath: book.coverImagePath,
            coverImageName: book.coverImageName,
            dateAdded: book.dateAdded,
            playDate: book.playDate,
            bookType: book.bookType,
            fileType: book.fileType,
            pages: book.pages,
            myRate: book.myRate,
            unseen: book.unseen,
            keywordA: book.keywordA,
            keywordB: book.keywordB,
            keywordC: book.keywordC,
            neta: book.neta,
            series: book.series,
            volume: book.volume
        )
    }

    private func anomalyID(_ anomaly: BookAnomaly) -> String {
        switch anomaly {
        case .dictKeyNotInteger(let raw):                return raw
        case .malformedBookEntry(let raw, _):            return raw
        case .missingRequiredField(let name):            return "(missing field: \(name))"
        case .malformedDate(let field):                  return "(malformed date: \(field))"
        case .dateOutOfRange(let field, _):              return "(date out of range: \(field))"
        }
    }

    /// Stackroom convention: thumbnails live at `<xml-parent>/Stackroom Library/<book-id>/thumbnail.jpg`.
    /// Returns `nil` when sourceURL is the placeholder `/dev/null` used in unit tests.
    private func inferThumbnailsDirectory(from sourceURL: URL) -> String? {
        guard sourceURL.path != "/dev/null" else { return nil }
        return sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Stackroom Library")
            .path
    }
}
