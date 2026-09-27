// SPDX-License-Identifier: MIT
import AppKit
import LibraryStore
import StackNestL10n

public enum HelperLauncher {
    /// 実際にアプリを起動する処理。**テストから差し替えるための継ぎ目。**
    /// 既定は `NSWorkspace` で開く。テストはここを差し替えて、本物のアプリを起動させない
    /// （かつて、テストが実在アプリに空の一時ファイルを開かせ、`defer` で消したせいで
    /// 「ファイルが見つかりません」のダイアログが開発機に溜まる事故があった）。
    @MainActor
    public static var launch: (_ fileURL: URL, _ viewerURL: URL) -> Void = { fileURL, viewerURL in
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: viewerURL, configuration: config) { _, _ in
            // Completion handler errors are intentionally ignored:
            // we have no synchronous channel to surface them to the alert UI.
        }
    }

    /// Opens `book.path` using the user-configured external viewer.
    /// path から `BookCategory.classify` で category を判定し、
    /// `settings.resolvedViewerPath(forPath:category:)` (= EPUB は専用指定 → default fallback、
    /// それ以外は category override → default fallback) で viewer を解決する。
    /// EPUB 専用指定を見るのは category が `.text` の場合だけ。
    /// Returns `nil` if launch was dispatched, or an `AppError` describing the failure.
    @MainActor
    public static func open(book: BookRow, settings: ViewerSettings) -> AppError? {
        guard let path = book.path, !path.isEmpty else {
            return .launchFailed(path: "(empty)", reason: L10n.text("書籍にパスが設定されていません。"))
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .launchFailed(
                path: path,
                reason: L10n.text("ファイルが見つかりません。")
            )
        }

        let category = BookCategory.classify(path: path)
        // G54-S2b: EPUB だけ専用の指定を先に引く（無ければ `.text` を飛ばして既定）。
        guard let viewerPath = settings.resolvedViewerPath(forPath: path, category: category) else {
            // G54-S2b: EPUB は `.text` に分類されるが、テキストの指定は経由しないので名前も分ける。
            let viewerKindName = (category == .text && (path as NSString).pathExtension.lowercased() == "epub")
                ? L10n.text("電子書籍") : category.displayName
            return .launchFailed(
                path: path,
                reason: L10n.format("%@ 用の外部ビューアが未設定です。設定 (⌘,) で選択してください。", viewerKindName)
            )
        }
        guard FileManager.default.fileExists(atPath: viewerPath) else {
            return .launchFailed(
                path: path,
                reason: L10n.format("外部ビューアが見つかりません: %@\n設定 (⌘,) で再選択してください。", viewerPath)
            )
        }
        let viewerURL = URL(fileURLWithPath: viewerPath)
        let fileURL = URL(fileURLWithPath: path)
        launch(fileURL, viewerURL)
        return nil
    }
}
