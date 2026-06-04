// SPDX-License-Identifier: MIT
import Foundation
import StackroomFormat

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

    public init(database: Database, seriesVolumeParser: SeriesVolumeParser? = nil) {
        self.database = database
        self.seriesVolumeParser = seriesVolumeParser
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

        for (_, book) in document.books {
            let finalBook = filledBook(book)
            try database.insertBook(finalBook)
            summary.imported += 1
            processed += 1
            progress?.reportProgress(processed: processed, total: total)
        }

        for anomaly in document.anomalies {
            summary.skipped.append(
                SkippedBook(id: anomalyID(anomaly), reason: anomaly.localizedDescription)
            )
            processed += 1
            progress?.reportProgress(processed: processed, total: total)
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
