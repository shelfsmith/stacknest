// SPDX-License-Identifier: MIT
import Foundation
import ArchiveAdapter

/// 単一 book の thumbnail.jpg を抽出 + 保存する純粋ユーティリティ。
/// - 新規 book 追加時 (BookImporter / BookAddCoordinator) 経路
/// - 既存 book の cover_image_name 変更時 (AppState.regenerateThumbnail) 経路
/// の両方で再利用される。
public enum CoverRefresher {
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
