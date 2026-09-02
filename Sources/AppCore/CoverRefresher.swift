// SPDX-License-Identifier: MIT
import Foundation
import ArchiveAdapter
import EPUBAdapter

/// G21 followup Important #2: `extractCoverData` が表紙を作れないと判定した形式
/// （動画・epub・txt/md/rtf 等、フォルダ/アーカイブ/PDF/単独画像のいずれでもないもの）。
/// 呼び出し側（サーバは HTTP 4xx、App はログのみ）でハンドリングする。
public enum CoverRefreshError: Error, Sendable, Equatable {
    case unsupportedFormat
}

/// 単一 book の thumbnail.jpg を抽出 + 保存する純粋ユーティリティ。
/// - 新規 book 追加時 (BookImporter / BookAddCoordinator) 経路
/// - 既存 book の cover_image_name 変更時 (AppState.regenerateThumbnail) 経路
/// の両方で再利用される。
public enum CoverRefresher {
    /// G21 followup Important #2: フォーマット非依存の表紙データ抽出（書き込みは行わない）。
    /// フォルダ/zip 系アーカイブは既存の `ArchiveAdapter.coverExtractor` 経由、単独 PDF は
    /// `PDFBookContent.coverJPEG`（CoverCompression の whole-library ジョブと同じ分岐を再利用）、
    /// 単独画像はファイルをそのまま読む。対応不可な形式は `.unsupportedFormat` を throw する
    /// （zip 内に画像もフォールバック PDF も無い等、既存 extractor が nil を返さず失敗する
    /// ケースはそのまま extractor 側のエラーが伝播する）。
    ///
    /// re-review Important fix: PDF レンダリング（`PDFBookContent.coverJPEG`、同期の CG 描画）と
    /// 単独画像の `Data(contentsOf:)`（同期ファイル I/O）は、フォルダ/zip 系の
    /// `ArchiveAdapter` 実装（`FolderCoverExtractor`/`LibarchiveCoverExtractor`）と違って
    /// 元々どこも off-actor 化していない。呼び出し元が `@MainActor`（App の
    /// `AppState.regenerateThumbnail`）だと、この関数の同期区間はそのまま MainActor 上で
    /// 実行されてしまい、PDF 1 冊ごとに main thread をブロックする（フォルダ一括リマップで
    /// 対象が数百冊になると顕著）。本体全体を `Task.detached` に包み、呼び出し元がどの actor でも
    /// 同期区間がそこに乗らないようにする（`ArchiveAdapter` 側は内部で既に detach しているため
    /// 二重 detach になるが、正当性・安全性上の問題はない）。
    public static func extractCoverData(sourceURL: URL, preferredName: String?) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            if sourceURL.pathExtension.lowercased() == "pdf" {
                guard let pdf = PDFBookContent(url: sourceURL),
                      let data = pdf.coverJPEG(maxPixelSize: 1200) else {
                    throw CoverRefreshError.unsupportedFormat
                }
                return data
            }
            // G48: EPUB は契約 `EPUBAdapter.reader` に回す（Washi は AppCore から見えない）。
            // 未登録・表紙なし → 既存の「作れない」経路（unsupportedFormat）。
            if sourceURL.pathExtension.lowercased() == "epub" {
                guard let reader = EPUBAdapter.reader,
                      let data = try await reader.coverImageData(url: sourceURL, maxPixelSize: 1200) else {
                    throw CoverRefreshError.unsupportedFormat
                }
                return data
            }
            if let extractor = ArchiveAdapter.coverExtractor(for: sourceURL) {
                return try await extractor.extractCoverImage(from: sourceURL, preferredName: preferredName)
            }
            if Self.standaloneImageExtensions.contains(sourceURL.pathExtension.lowercased()) {
                return try Data(contentsOf: sourceURL)
            }
            throw CoverRefreshError.unsupportedFormat
        }.value
    }

    /// `BookCategory.classify(path:)` の `.image` 判定と同じ拡張子集合（Sources/AppCore/BookCategory.swift）。
    private static let standaloneImageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]

    /// re-review Important fix: `CoverImageResizer.resizeJPEG` は CGImageSource デコード + JPEG
    /// 再エンコードという相応に重い CPU 処理。`extractCoverData` 同様、呼び出し元の actor
    /// （MainActor 含む）をブロックしないよう detach する。
    public static func resizeCoverDataOffMain(_ data: Data, maxPixelSize: Int) async -> Data {
        await Task.detached(priority: .userInitiated) {
            CoverImageResizer.resizeJPEG(data, maxPixelSize: maxPixelSize)
        }.value
    }

    /// `Thumbnails/<bookID>/thumbnail.jpg` に表紙画像を保存する。
    /// - Parameters:
    ///   - bookID: 対象 book の DB id
    ///   - sourceURL: アーカイブ or フォルダの絶対 URL
    ///   - preferredName: 手動指定の cover_image_name (nil = 自動先頭)
    ///   - thumbnailsDirURL: bundle 内の Thumbnails ディレクトリ URL
    ///   - extractor: 該当 source に対応する CoverImageExtractor (caller が dispatch 済み)
    public static func regenerate(
        bookID: Int,
        sourceURL: URL,
        preferredName: String?,
        thumbnailsDirURL: URL,
        extractor: any CoverImageExtractor
    ) async throws {
        let imageData = try await extractor.extractCoverImage(from: sourceURL, preferredName: preferredName)
        let bookDir = thumbnailsDirURL.appendingPathComponent("\(bookID)")
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        let thumbURL = bookDir.appendingPathComponent("thumbnail.jpg")
        // Phase 2.5h B19: storage 段階で UI 上限 px (1200) へ resize して保存。
        // 元画像が 1200 px 以下ならそのまま (品質維持)。
        let resized = CoverImageResizer.resizeJPEG(imageData, maxPixelSize: 1200)
        try resized.write(to: thumbURL)
    }

    /// 外部画像データから直接 thumbnail.jpg を生成する（アーカイブ抽出なし・G4a 外部表紙）。
    public static func regenerateFromImageData(bookID: Int, imageData: Data, thumbnailsDirURL: URL) throws {
        let bookDir = thumbnailsDirURL.appendingPathComponent("\(bookID)")
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        let thumbURL = bookDir.appendingPathComponent("thumbnail.jpg")
        let resized = CoverImageResizer.resizeJPEG(imageData, maxPixelSize: 1200)
        try resized.write(to: thumbURL)
    }
}
