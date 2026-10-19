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
        launchMany([fileURL], viewerURL)
    }

    /// 複数のファイルを 1 回の `open` でまとめて渡す処理（`launch` と同じく試験の継ぎ目）。Finder で複数を選んで
    /// 開いたときと同じく、アプリには 1 回の「開く」として届く（`application(_:open:)` が 1 回で全部を受け取れる）。
    @MainActor
    public static var launchMany: (_ fileURLs: [URL], _ viewerURL: URL) -> Void = { fileURLs, viewerURL in
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(fileURLs, withApplicationAt: viewerURL, configuration: config) { _, _ in
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

    /// G60: 参照ファイルを渡すビューアの種類（アーカイブ・フォルダ・画像以外はアーカイブの指定で引く）。
    /// ローカルの本はパスから決める（フォルダはディスク上のディレクトリとして判定される）。
    public static func referenceCategory(bookPath: String) -> BookCategory {
        referenceViewerCategory(BookCategory.classify(path: bookPath))
    }

    /// G60: リモートの本の参照ファイルを渡すビューアの種類。サーバの manifest の `format` から決める
    /// （リモートのフォルダの本は filename に拡張子が無く、パスからはアーカイブに倒れてしまうため）。
    /// `archive`・`folder`・`image` はそれぞれの指定、それ以外（PDF の `text`、画像の EPUB など）はアーカイブの指定。
    public static func referenceCategory(manifestFormat: String) -> BookCategory {
        switch manifestFormat {
        case "archive": return .archive
        case "folder": return .folder
        case "image": return .image
        default: return .archive
        }
    }

    /// アーカイブ・フォルダ・画像はそのまま、それ以外（動画・テキスト）はアーカイブの指定に寄せる。
    private static func referenceViewerCategory(_ classified: BookCategory) -> BookCategory {
        switch classified {
        case .archive, .folder, .image: return classified
        default: return .archive
        }
    }

    /// G60 v3: 参照ファイルを渡す外部ビューア（設定済みで実在し、`StackNestViewerSupport` で StackNest が書ける版を
    /// 宣言しているもの）。トークンを出す前に引く。nil なら渡さず、従来の開き方に任せる。ローカルの本用（パスから種類を決める）。
    @MainActor
    public static func referenceViewer(bookPath: String, settings: ViewerSettings) -> ReferenceViewer? {
        referenceViewer(category: referenceCategory(bookPath: bookPath), settings: settings)
    }

    /// G60 v3: 参照ファイルを渡す外部ビューア。種類は呼び出し側が決める（リモートの本は `referenceCategory(manifestFormat:)`）。
    @MainActor
    public static func referenceViewer(category: BookCategory, settings: ViewerSettings) -> ReferenceViewer? {
        guard let path = settings.resolvedViewerPath(for: referenceViewerCategory(category)) else { return nil }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return ReferenceViewer.resolve(appURL: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// G60 v3: 参照ファイルを、**対応を確かめたビューア**（`ReferenceViewer.appURL`）で開く。設定を引き直さない
    /// （確認と起動の間に設定が変わっても、確かめたアプリに渡す）。実在の見張りは残す。
    @MainActor
    public static func openReference(_ referenceURL: URL, viewer: ReferenceViewer) -> AppError? {
        openReferences([referenceURL], viewer: viewer)
    }

    /// 複数の参照ファイルを、1 回の `open` でまとめて同じビューアへ渡す（1 つなら `openReference` と同じ道）。
    /// 複数の本を選んで開いたとき、ビューアがそれを 1 回の選択として受け取れるようにする（1 冊ずつ `open` すると
    /// 別々の「開く」として届き、ビューアには組がどこまでか分からない）。
    @MainActor
    public static func openReferences(_ referenceURLs: [URL], viewer: ReferenceViewer) -> AppError? {
        guard let first = referenceURLs.first else { return nil }
        guard FileManager.default.fileExists(atPath: viewer.appURL.path) else {
            return .launchFailed(
                path: first.lastPathComponent,
                reason: L10n.format("外部ビューアが見つかりません: %@\n設定 (⌘,) で再選択してください。", viewer.appURL.path)
            )
        }
        if referenceURLs.count == 1 {
            launch(first, viewer.appURL)
        } else {
            // 1 回の `open` に載せるのは `maxReferencesPerOpen` 個まで（Apple Event の大きさを抑える。数千冊を選んでも
            // 1 つの巨大なイベントにしない）。分けた残りは続けて渡す。
            var start = referenceURLs.startIndex
            while start < referenceURLs.endIndex {
                let end = min(start + maxReferencesPerOpen, referenceURLs.endIndex)
                launchMany(Array(referenceURLs[start..<end]), viewer.appURL)
                start = end
            }
        }
        return nil
    }

    /// 1 回の `open` で渡す参照ファイルの上限（`openReferences`）。
    public static let maxReferencesPerOpen = 200
}
