// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import OSLog

/// 内部表紙を再生成して 1200px cap を適用するバッチ（CoverRefresher が cap を内蔵）。
/// 外部表紙は対象外。ローカル App(CoverRegenerationTask) とリモートサーバの共有コア。
/// isCancelled は actor-isolated なキャンセル状態（サーバのジョブレジストリ）を読めるよう async。
public enum CoverCompression {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "CoverCompression")

    /// 内部表紙を再生成。progress(done,total)・isCancelled 対応。
    /// 戻り値は「実際に縮んだ件数」（beforeSize > afterSize、ローカルの bytesSavedEstimate と同じ判定）。
    @discardableResult
    public static func compressOversizedCovers(
        db: Database,
        bundleURL: URL,
        progress: sending (Int, Int) -> Void = { _, _ in },
        isCancelled: sending () async -> Bool = { false }
    ) async throws -> Int {
        let books = try db.fetchAllBooks()
        let total = books.count
        let thumbnailsDir = bundleURL.appendingPathComponent("Thumbnails")
        var shrunk = 0
        var processed = 0
        for book in books {
            if await isCancelled() { break }
            defer { processed += 1; progress(processed, total) }
            if CoverSource.isExternal(book.coverImageName) { continue }   // 外部表紙は再圧縮対象外（上書き防止）
            guard let pathStr = book.path else { continue }
            let sourceURL = URL(fileURLWithPath: pathStr)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                logger.warning("Source missing, skip book id=\(book.id, privacy: .public): \(pathStr, privacy: .public)")
                continue
            }
            let thumbURL = thumbnailsDir.appendingPathComponent("\(book.id)/thumbnail.jpg")
            let beforeSize = (try? FileManager.default.attributesOfItem(atPath: thumbURL.path)[.size] as? Int64) ?? 0

            // Codex review Important #3: 書き込み直前に最新状態を再確認する。上の isExternal チェックは
            // ループ開始時点のスナップショットに対するもので、await isCancelled() や extractor 処理中の
            // サスペンションの間に別クライアントが外部表紙をアップロードした場合、それをこのジョブが
            // 上書きしてしまう窓がある（初期スナップショットの skip だけでは防げない）。
            if let fresh = try? db.fetchBook(id: book.id), CoverSource.isExternal(fresh.coverImageName) { continue }

            // G22 #3: PDF/アーカイブの二分岐をやめ、単独 PDF・単独画像・アーカイブ・フォルダを一括で
            // 扱える共通抽出（CoverRefresher.extractCoverData・G21 #5 で単独画像対応済）に一本化する。
            // 旧二分岐は単独画像本（.jpg/.png 1 枚）を素通りさせていた。真に表紙を作れない形式は
            // CoverRefreshError.unsupportedFormat として log-only でスキップ（従来と同じ best-effort）。
            do {
                let data = try await CoverRefresher.extractCoverData(sourceURL: sourceURL, preferredName: book.coverImageName)
                let resized = await CoverRefresher.resizeCoverDataOffMain(data, maxPixelSize: 1200)
                let bookDir = thumbURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
                try resized.write(to: thumbURL)
            } catch CoverRefreshError.unsupportedFormat {
                logger.warning("Unsupported format, skip cover regenerate id=\(book.id, privacy: .public)")
            } catch {
                logger.warning("Cover regenerate failed id=\(book.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            let afterSize = (try? FileManager.default.attributesOfItem(atPath: thumbURL.path)[.size] as? Int64) ?? 0
            if beforeSize > afterSize { shrunk += 1 }
        }
        return shrunk
    }
}
