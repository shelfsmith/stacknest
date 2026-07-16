// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import AppCore
import LibraryStore
import OSLog

/// スレッド安全なキャンセルトークン。isCancelled クロージャは AppCore.CoverCompression の
/// nonisolated loop から呼ばれる（MainActor 外の可能性がある）ため、単純な MainActor プロパティの
/// キャプチャではなくロック付きフラグで安全に読み書きする（RemoteLibraryState.CancelFlag と同じ設計）。
private final class CoverRegenerationCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Phase 2.5h B19: ライブラリ内の全 thumbnail.jpg を CoverRefresher で再生成する。
/// 中断可能、idempotent。中間進捗は永続化しない (再開時はゼロから loop)。
///
/// 単独 .pdf は PDFBookContent 経由、それ以外 (zip/cbz/rar/cbr/7z/フォルダ) は
/// ArchiveAdapter + CoverRefresher 経由で再抽出する。CoverRefresher が C4 の 1200 px cap を
/// 内部で適用するため、本 task では追加 resize しない。ループ本体は AppCore.CoverCompression
/// （ローカル App とリモートサーバの共有コア）に委譲する。
@MainActor
final class CoverRegenerationTask {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "CoverRegeneration")

    let totalCount: Int
    private(set) var processedCount: Int = 0
    private(set) var bytesSavedEstimate: Int64 = 0
    private let cancelFlag = CoverRegenerationCancelFlag()
    var cancelled: Bool { cancelFlag.isCancelled }

    private let bundleURL: URL
    private let database: Database
    private let books: [BookRow]

    init(database: Database, bundleURL: URL) {
        self.database = database
        self.bundleURL = bundleURL
        self.books = (try? database.fetchAllBooks()) ?? []
        self.totalCount = books.count
    }

    func cancel() { cancelFlag.cancel() }

    /// loop body は AppCore.CoverCompression（ローカル App とリモートサーバの共有コア）へ委譲。
    /// progressives は onProgress callback で呼び出し側に通知。bytesSavedEstimate は
    /// コアが per-book delta を返さない（progress は (done,total) のみ）ため、Thumbnails
    /// ディレクトリ全体のサイズを実行前後でスナップショットして概算する（UI 表示 "約 X MB 削減" を維持）。
    func run(onProgress: @escaping @MainActor (Int, Int) -> Void) async {
        let thumbnailsDir = bundleURL.appendingPathComponent("Thumbnails")
        let sizeBefore = Self.totalSize(of: thumbnailsDir)
        let shrunkCount = (try? await CoverCompression.compressOversizedCovers(
            db: database,
            bundleURL: bundleURL,
            progress: { done, total in
                Task { @MainActor [weak self] in
                    self?.processedCount = done
                    onProgress(done, total)
                }
            },
            isCancelled: { [cancelFlag] in cancelFlag.isCancelled }
        )) ?? 0
        let sizeAfter = Self.totalSize(of: thumbnailsDir)
        bytesSavedEstimate = max(0, sizeBefore - sizeAfter)
        Self.logger.info("CoverRegenerationTask done: \(self.processedCount, privacy: .public)/\(self.totalCount, privacy: .public), shrunk ~\(shrunkCount, privacy: .public) covers, saved ~\(self.bytesSavedEstimate, privacy: .public) bytes")
    }

    /// Thumbnails ディレクトリ配下の総ファイルサイズ（bytesSavedEstimate 算出用）。
    private static func totalSize(of url: URL) -> Int64 {
        var sum: Int64 = 0
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        for case let f as URL in en {
            sum += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return sum
    }
}
