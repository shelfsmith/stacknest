// SPDX-License-Identifier: MIT
import AppKit
import LibraryStore

public enum HelperLauncher {
    /// Opens `book.path` using the user-configured external viewer.
    /// path から `BookCategory.classify` で category を判定し、
    /// `settings.resolvedViewerPath(for:)` (= category override → default fallback) で viewer を解決する。
    /// Returns `nil` if launch was dispatched, or an `AppError` describing the failure.
    @MainActor
    public static func open(book: BookRow, settings: ViewerSettings) -> AppError? {
        guard let path = book.path, !path.isEmpty else {
            return .launchFailed(path: "(empty)", reason: "書籍にパスが設定されていません。")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .launchFailed(
                path: path,
                reason: "ファイルが見つかりません。"
            )
        }

        let category = BookCategory.classify(path: path)
        guard let viewerPath = settings.resolvedViewerPath(for: category) else {
            return .launchFailed(
                path: path,
                reason: "\(category.displayName) 用の外部ビューワが未設定です。設定 (⌘,) で選択してください。"
            )
        }
        guard FileManager.default.fileExists(atPath: viewerPath) else {
            return .launchFailed(
                path: path,
                reason: "外部ビューワが見つかりません: \(viewerPath)\n設定 (⌘,) で再選択してください。"
            )
        }
        let viewerURL = URL(fileURLWithPath: viewerPath)
        let fileURL = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: viewerURL, configuration: config) { _, _ in
            // Completion handler errors are intentionally ignored:
            // we have no synchronous channel to surface them to the alert UI.
        }
        return nil
    }
}
