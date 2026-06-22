// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import ArchiveAdapter
import StackroomFormat
import OSLog

/// headless 取り込みコア。GUI / CLI / サーバ / MCP から再利用できる純粋な Sendable 型。
/// ViewerSettings・AppKit・SwiftUI への依存を持たない。
public struct BookImporter: Sendable {
    private let database: Database
    private let bundleURL: URL
    private let format: FilenameFormat
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "BookImporter")

    // fileType integer values matching Stackroom convention (stored in book.file_type)
    private enum FileTypeCode {
        static let zip = 2      // zip / cbz
        static let rar = 3      // cbr / rar
        static let folder = 4   // image folder set
        static let sevenZ = 5   // 7z / cb7
    }

    public struct ImportResult: @unchecked Sendable {
        public var addedIDs: [Int] = []
        public var coverFailures: [URL] = []
        public var alreadyPresent: [URL] = []
        /// Entries where insert or I/O failed. Error is not formally Sendable, hence @unchecked.
        public var failed: [(URL, any Error)] = []
        public init() {}
    }

    public init(database: Database, bundleURL: URL, format: FilenameFormat) {
        self.database = database
        self.bundleURL = bundleURL
        self.format = format
    }

    /// Adds the given URLs as books. Returns a summary; UI is responsible for showing it.
    /// - Parameters:
    ///   - urls: ファイル / フォルダ URL のリスト
    ///   - autoClassifyEnabled: 自動分類を有効化するか (ViewerSettings.shared を読まない)
    ///   - thickThreshold: archive の page 数閾値 (autoClassifyEnabled == true 時のみ参照)
    public func add(urls: [URL], autoClassifyEnabled: Bool, thickThreshold: Int) async -> ImportResult {
        var result = ImportResult()
        let existingPaths = (try? Set(database.fetchAllBooks().map { $0.path ?? "" })) ?? []
        let thumbnailsDir = bundleURL.appendingPathComponent("Thumbnails")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)

        // Sequential execution keeps DB writes serial (safe for auto-increment ID retrieval)
        for url in urls {
            if existingPaths.contains(url.path) {
                result.alreadyPresent.append(url)
                continue
            }
            do {
                // 1. page count を確定 + PDF fallback で cover data を取得 (画像 first hit 優先)。
                var pageCount = 0
                var coverDataOverride: Data? = nil
                let archiveExtractor = ArchiveAdapter.coverExtractor(for: url)
                if let extractor = archiveExtractor {
                    pageCount = (try? await extractor.countImageEntries(in: url)) ?? 0
                    if pageCount == 0,
                       let pdfData = try? await extractor.extractFirstPDFData(in: url) {
                        // archive 内 PDF fallback: 一時ファイルに展開 → PDFBookContent
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
                        do {
                            try pdfData.write(to: tmp)
                            if let content = PDFBookContent(url: tmp) {
                                pageCount = content.pageCount
                                coverDataOverride = content.coverJPEG(maxPixelSize: 1200)
                            }
                        } catch {
                            Self.logger.warning("PDF fallback temp-write failed for \(url.lastPathComponent): \(error.localizedDescription)")
                        }
                        try? FileManager.default.removeItem(at: tmp)
                    }
                } else if url.pathExtension.lowercased() == "pdf" {
                    // 単独 PDF
                    if let content = PDFBookContent(url: url) {
                        pageCount = content.pageCount
                        coverDataOverride = content.coverJPEG(maxPixelSize: 1200)
                    }
                } else if BookCategory.classify(path: url.path) == .image {
                    // Phase 2.5g+h+i fixup v1: 単独 image を追加した場合、その image を
                    // そのまま thumbnail として使う (resize は CoverImageResizer で 1200 px 化)。
                    pageCount = 1
                    if let raw = try? Data(contentsOf: url) {
                        coverDataOverride = CoverImageResizer.resizeJPEG(raw, maxPixelSize: 1200)
                    }
                }

                // 2. bookType を確定 (自動分類 ON 時は BookTypeClassifier、OFF 時は旧挙動)。
                let bookType: Int
                if autoClassifyEnabled {
                    bookType = BookTypeClassifier.autoClassify(
                        url: url, pageCount: pageCount, thickThreshold: thickThreshold
                    )
                } else {
                    // 旧挙動: フォルダ → 3、それ以外 → 0
                    var isDir: ObjCBool = false
                    _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    bookType = isDir.boolValue ? 3 : 0
                }

                // 3. insert (bookType を引数で渡す)
                let id = try insertBookRecord(for: url, bookType: bookType)
                result.addedIDs.append(id)

                if pageCount > 0 {
                    try? database.updateBookPages(id: id, newPages: pageCount)
                }

                // 4. stale thumbnail を掃除してから cover 書き出し
                let bookThumbDir = thumbnailsDir.appendingPathComponent(String(id))
                let staleThumb = bookThumbDir.appendingPathComponent("thumbnail.jpg")
                if FileManager.default.fileExists(atPath: staleThumb.path) {
                    try? FileManager.default.removeItem(at: staleThumb)
                    Self.logger.warning("Pre-write: removed stale thumbnail.jpg for book \(id)")
                }

                if let cover = coverDataOverride {
                    // 表紙 data override 経路 — PDFBookContent.coverJPEG / CoverImageResizer.resizeJPEG
                    // のいずれかで生成済 (どちらも 1200 px 上限を保証)。
                    do {
                        try FileManager.default.createDirectory(at: bookThumbDir, withIntermediateDirectories: true)
                        try cover.write(to: staleThumb)
                    } catch {
                        Self.logger.warning("Cover write failed for \(url.lastPathComponent): \(error.localizedDescription)")
                        result.coverFailures.append(url)
                    }
                } else if let extractor = archiveExtractor {
                    // 画像 first hit (現行) — CoverRefresher が B19 1200 px resize を担当
                    do {
                        try await CoverRefresher.regenerate(
                            bookID: id,
                            sourceURL: url,
                            preferredName: nil,
                            thumbnailsDirURL: thumbnailsDir,
                            extractor: extractor
                        )
                    } catch {
                        Self.logger.warning("Cover extract failed for \(url.lastPathComponent): \(error.localizedDescription)")
                        result.coverFailures.append(url)
                    }
                } else {
                    // Unsupported format for cover extraction — not an error, just no thumbnail
                    result.coverFailures.append(url)
                }
            } catch {
                result.failed.append((url, error))
            }
        }
        return result
    }

    /// Builds a BookRecord from the URL and inserts it, returning the auto-assigned row id.
    /// `bookType` は caller 側で自動分類済みの値を渡す (Phase 2.5g).
    private func insertBookRecord(for url: URL, bookType: Int) throws -> Int {
        let basename = url.deletingPathExtension().lastPathComponent
        // Parse format fields for non-title metadata (author, genre, keywords, etc.).
        // Title is always set to basename verbatim — FilenameFormatter reverse-parse may split
        // "Naruto Vol.7" into title="Naruto Vol" + volume=7, which is wrong for the title field.
        // B2 reverse-parser principle: title is immutable; only series/volume are auto-extracted.
        let fields = FilenameFormatter.makeBookFields(fromBasename: basename, with: format)

        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        // fileType だけ caller 側で確定 (bookType は引数で受け取る — Phase 2.5g)
        let fileType: Int
        if isDir.boolValue {
            fileType = FileTypeCode.folder
        } else {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "cbr", "rar":
                fileType = FileTypeCode.rar
            case "7z", "cb7":
                fileType = FileTypeCode.sevenZ
            default:
                fileType = FileTypeCode.zip
            }
        }

        // Use fields[.title] when the format successfully extracted a title token (e.g., custom
        // format "(@genre) [@author] @title" correctly isolates the title from surrounding metadata).
        // Fall back to basename when fields[.title] is nil or empty (parse failed / no @title token).
        //
        // Previously this was unconditionally `basename` (commit 312e33d) to avoid a "double-strip"
        // bug where FilenameFormatter.parse() called deletingPathExtension internally, truncating
        // "Naruto Vol.7" → "Naruto Vol". That internal strip has been removed from parse(); stems
        // are now parsed verbatim, so using fields[.title] is safe again.
        let resolvedTitle: String
        if let fieldTitle = fields[.title], !fieldTitle.isEmpty {
            resolvedTitle = fieldTitle
        } else {
            resolvedTitle = basename
        }
        let parsed = FilenameParser.parse(title: resolvedTitle, filename: url.lastPathComponent)

        let record = BookRecord(
            id: 0,  // placeholder — insertBookReturningID uses auto-assign (omits id column)
            title: resolvedTitle,
            author: fields[.author],
            genre: fields[.genre],
            path: url.path,
            coverImagePath: "",
            dateAdded: Date(),
            bookType: bookType,
            fileType: fileType,
            keywordA: fields[.keywordA],
            keywordB: fields[.keywordB],
            neta: fields[.relation],
            series: parsed.series,
            volume: parsed.volume
        )
        return try database.insertBookReturningID(record)
    }
}
