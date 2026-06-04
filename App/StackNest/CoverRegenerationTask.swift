// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import AppCore
import LibraryStore
import ArchiveAdapter
import OSLog

/// Phase 2.5h B19: ライブラリ内の全 thumbnail.jpg を CoverRefresher で再生成する。
/// 中断可能、idempotent。中間進捗は永続化しない (再開時はゼロから loop)。
///
/// 単独 .pdf は PDFBookContent 経由、それ以外 (zip/cbz/rar/cbr/7z/フォルダ) は
/// ArchiveAdapter + CoverRefresher 経由で再抽出する。CoverRefresher が C4 の 1200 px cap を
/// 内部で適用するため、本 task では追加 resize しない。
@MainActor
final class CoverRegenerationTask {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "CoverRegeneration")

    let totalCount: Int
    private(set) var processedCount: Int = 0
    private(set) var bytesSavedEstimate: Int64 = 0
    private(set) var cancelled = false

    private let bundleURL: URL
    private let database: Database
    private let books: [BookRow]

    init(database: Database, bundleURL: URL) {
        self.database = database
        self.bundleURL = bundleURL
        self.books = (try? database.fetchAllBooks()) ?? []
        self.totalCount = books.count
    }

    func cancel() { cancelled = true }

    /// loop body; progressives は onProgress callback で呼び出し側に通知。
    func run(onProgress: @escaping @MainActor (Int, Int) -> Void) async {
        let thumbnailsDir = bundleURL.appendingPathComponent("Thumbnails")
        for book in books {
            if cancelled { break }
            defer {
                processedCount += 1
                onProgress(processedCount, totalCount)
            }
            guard let pathStr = book.path else { continue }
            let sourceURL = URL(fileURLWithPath: pathStr)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                Self.logger.warning("Source missing, skip book id=\(book.id, privacy: .public): \(pathStr, privacy: .public)")
                continue
            }
            let thumbURL = thumbnailsDir.appendingPathComponent("\(book.id)/thumbnail.jpg")
            let beforeSize = (try? FileManager.default.attributesOfItem(atPath: thumbURL.path)[.size] as? Int64) ?? 0

            // PDF / extractor 分岐: 単独 PDF は PDFBookContent、それ以外は ArchiveAdapter。
            if sourceURL.pathExtension.lowercased() == "pdf",
               let content = PDFBookContent(url: sourceURL),
               let pdfCover = content.coverJPEG(maxPixelSize: 1200) {
                let bookDir = thumbURL.deletingLastPathComponent()
                do {
                    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
                    try pdfCover.write(to: thumbURL)
                } catch {
                    Self.logger.warning("PDF cover write failed for book id=\(book.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            } else if let extractor = ArchiveAdapter.coverExtractor(for: sourceURL) {
                do {
                    try await CoverRefresher.regenerate(
                        bookID: book.id,
                        sourceURL: sourceURL,
                        preferredName: book.coverImageName,
                        thumbnailsDirURL: thumbnailsDir,
                        extractor: extractor
                    )
                } catch {
                    Self.logger.warning("Cover regenerate failed for book id=\(book.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

            let afterSize = (try? FileManager.default.attributesOfItem(atPath: thumbURL.path)[.size] as? Int64) ?? 0
            if beforeSize > afterSize {
                bytesSavedEstimate += (beforeSize - afterSize)
            }
        }
        Self.logger.info("CoverRegenerationTask done: \(self.processedCount, privacy: .public)/\(self.totalCount, privacy: .public), saved ~\(self.bytesSavedEstimate, privacy: .public) bytes")
    }
}
