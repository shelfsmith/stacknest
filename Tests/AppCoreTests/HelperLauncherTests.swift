// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import LibraryStore

/// `HelperLauncher.launch` は `@MainActor` の static var（テスト用の継ぎ目）を差し替えるため、
/// 並行実行させると他テストの上書きと競合する。`.serialized` で直列化する
/// （前例: `Tests/LibraryServerTests/ImportConfigEndpointTests.swift`）。
@Suite("HelperLauncherTests", .serialized)
struct HelperLauncherTests {
    private func makeBook(path: String?, coverPath: String) -> BookRow {
        BookRow(
            id: 1,
            title: "test",
            author: nil,
            genre: nil,
            path: path,
            dateAdded: Date(),
            playDate: nil,
            bookType: 0,
            fileType: 0,
            pages: nil,
            rating: 0,
            unseen: false,
            keywordA: nil,
            keywordB: nil,
            keywordC: nil,
            neta: nil
        )
    }

    /// `HelperLauncher.launch` を「呼ばれたことだけ記録する」ものに差し替える。
    /// 呼び出し元は必ず `defer` で復元すること（既定の `NSWorkspace` 経由の起動は
    /// 開発機で実在アプリを開いてしまうため、テストからは絶対に走らせない）。
    @MainActor
    private func recordingLaunch(into calls: RecordedCalls) -> (URL, URL) -> Void {
        { fileURL, viewerURL in
            calls.entries.append((fileURL: fileURL, viewerURL: viewerURL))
        }
    }

    /// launch 呼び出しを溜めるための箱。クロージャからの capture 用に reference 型にする。
    @MainActor
    private final class RecordedCalls {
        var entries: [(fileURL: URL, viewerURL: URL)] = []
    }

    @Test @MainActor
    func returnsErrorWhenViewerNotSet() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let calls = RecordedCalls()
        let originalLaunch = HelperLauncher.launch
        defer { HelperLauncher.launch = originalLaunch }
        HelperLauncher.launch = recordingLaunch(into: calls)
        let settings = ViewerSettings(defaults: suite)
        // book file は実在させて「file 不在」error を回避し、「viewer 未設定」error path を test
        let tempZip = FileManager.default.temporaryDirectory
            .appending(path: "HelperLauncher-\(UUID().uuidString).zip")
        try Data().write(to: tempZip)
        defer { try? FileManager.default.removeItem(at: tempZip) }
        let book = makeBook(path: tempZip.path(percentEncoded: false), coverPath: "/some/cover.jpg")
        let err = HelperLauncher.open(book: book, settings: settings)
        guard let err else {
            Issue.record("Expected non-nil AppError, got nil")
            return
        }
        if case let .launchFailed(_, reason) = err {
            #expect(reason.contains("設定"))
            #expect(reason.contains("⌘,"))
            #expect(reason.contains("アーカイブ"))  // category 名が含まれる
        } else {
            Issue.record("Expected .launchFailed, got \(err)")
        }
        #expect(calls.entries.isEmpty)  // viewer 未設定で弾かれているので launch には到達しない
    }

    @Test @MainActor
    func returnsErrorWhenBookHasNoPath() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let calls = RecordedCalls()
        let originalLaunch = HelperLauncher.launch
        defer { HelperLauncher.launch = originalLaunch }
        HelperLauncher.launch = recordingLaunch(into: calls)
        let settings = ViewerSettings(defaults: suite)
        settings.externalViewerAppPath = "/System/Applications/Preview.app"
        let book = makeBook(path: nil, coverPath: "")
        let err = HelperLauncher.open(book: book, settings: settings)
        guard let err else {
            Issue.record("Expected non-nil AppError, got nil")
            return
        }
        if case let .launchFailed(_, reason) = err {
            #expect(reason.contains("パスが設定されていません"))
        } else {
            Issue.record("Expected .launchFailed, got \(err)")
        }
        #expect(calls.entries.isEmpty)  // path 不在で弾かれているので launch には到達しない
    }

    @Test @MainActor
    func returnsErrorWhenViewerMissing() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let calls = RecordedCalls()
        let originalLaunch = HelperLauncher.launch
        defer { HelperLauncher.launch = originalLaunch }
        HelperLauncher.launch = recordingLaunch(into: calls)
        let settings = ViewerSettings(defaults: suite)
        settings.externalViewerAppPath = "/Applications/NoSuchApp\(UUID().uuidString).app"
        // book file は実在させて「file 不在」error を回避し、「viewer 実体不在」error path を test
        let tempZip = FileManager.default.temporaryDirectory
            .appending(path: "HelperLauncher-\(UUID().uuidString).zip")
        try Data().write(to: tempZip)
        defer { try? FileManager.default.removeItem(at: tempZip) }
        let book = makeBook(path: tempZip.path(percentEncoded: false), coverPath: "")
        let err = HelperLauncher.open(book: book, settings: settings)
        guard let err else {
            Issue.record("Expected non-nil AppError, got nil")
            return
        }
        if case let .launchFailed(_, reason) = err {
            #expect(reason.contains("外部ビューアが見つかりません"))
            #expect(reason.contains("再選択"))
        } else {
            Issue.record("Expected .launchFailed, got \(err)")
        }
        #expect(calls.entries.isEmpty)  // viewer 実体不在で弾かれているので launch には到達しない
    }

    @Test @MainActor
    func returnsErrorWhenFileMissing() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let calls = RecordedCalls()
        let originalLaunch = HelperLauncher.launch
        defer { HelperLauncher.launch = originalLaunch }
        HelperLauncher.launch = recordingLaunch(into: calls)
        let settings = ViewerSettings(defaults: suite)
        settings.externalViewerAppPath = "/System/Applications/Preview.app"
        let book = makeBook(path: "/nonexistent/path/\(UUID().uuidString).zip", coverPath: "")
        let err = HelperLauncher.open(book: book, settings: settings)
        guard let err else {
            Issue.record("Expected non-nil AppError, got nil")
            return
        }
        if case let .launchFailed(_, reason) = err {
            #expect(reason.contains("ファイルが見つかりません"))
        } else {
            Issue.record("Expected .launchFailed, got \(err)")
        }
        #expect(calls.entries.isEmpty)  // file 不在で弾かれているので launch には到達しない
    }

    @Test @MainActor
    func dispatchesToCategoryOverrideForArchive() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        settings.externalViewerAppPath = "/System/Applications/Preview.app"
        settings.categoryViewerPaths[.archive] = "/System/Applications/TextEdit.app"
        // resolvedViewerPath は archive override を返すはず
        #expect(settings.resolvedViewerPath(for: .archive) == "/System/Applications/TextEdit.app")
    }

    @Test @MainActor
    func dispatchesToDefaultWhenCategoryUnset() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        settings.externalViewerAppPath = "/System/Applications/Preview.app"
        // image category は未設定 → default に fallback
        #expect(settings.resolvedViewerPath(for: .image) == "/System/Applications/Preview.app")
    }

    @Test @MainActor
    func errorMessageMentionsCategoryWhenUnset() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let calls = RecordedCalls()
        let originalLaunch = HelperLauncher.launch
        defer { HelperLauncher.launch = originalLaunch }
        HelperLauncher.launch = recordingLaunch(into: calls)
        let settings = ViewerSettings(defaults: suite)
        let tempImage = FileManager.default.temporaryDirectory
            .appending(path: "HelperLauncher-\(UUID().uuidString).jpg")
        try Data().write(to: tempImage)
        defer { try? FileManager.default.removeItem(at: tempImage) }
        let book = makeBook(path: tempImage.path(percentEncoded: false), coverPath: "")
        let err = HelperLauncher.open(book: book, settings: settings)
        guard let err, case let .launchFailed(_, reason) = err else {
            Issue.record("Expected .launchFailed")
            return
        }
        // image category の displayName が含まれる
        #expect(reason.contains("画像"))
        #expect(calls.entries.isEmpty)  // viewer 未設定で弾かれているので launch には到達しない
    }

    @Test("G54-S2b: EPUB は専用指定のアプリで開く")
    @MainActor
    func epubUsesItsOwnViewer() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let calls = RecordedCalls()
        let originalLaunch = HelperLauncher.launch
        defer { HelperLauncher.launch = originalLaunch }
        HelperLauncher.launch = recordingLaunch(into: calls)
        let settings = ViewerSettings(defaults: suite)
        // .text の category override を別アプリに設定 -- EPUB の専用指定に負けることを確かめたい対照。
        // 実在確認は HelperLauncher 内で fileExists により行われるだけで、launch は継ぎ目経由なので
        // 実際に起動されることはない。
        settings.categoryViewerPaths[.text] = "/System/Applications/TextEdit.app"
        settings.epubViewerAppPath = "/System/Applications/Preview.app"
        let tempEPUB = FileManager.default.temporaryDirectory
            .appending(path: "HelperLauncher-\(UUID().uuidString).epub")
        try Data().write(to: tempEPUB)
        defer { try? FileManager.default.removeItem(at: tempEPUB) }
        let book = makeBook(path: tempEPUB.path(percentEncoded: false), coverPath: "")
        let err = HelperLauncher.open(book: book, settings: settings)
        // 専用指定（実在パス）が選ばれるので、起動は成功しエラーは返らない。
        #expect(err == nil)
        // 継ぎ目で記録した実際の呼び出しを直接見て、category override（TextEdit）ではなく
        // 専用指定（Preview）が渡されたことを確かめる -- 「エラーが返らない」だけでは
        // category override が選ばれていても同じ結果になり証拠にならなかったため、ここを強化した。
        guard let call = calls.entries.first else {
            Issue.record("Expected launch to be called once, got none")
            return
        }
        #expect(calls.entries.count == 1)
        // URL(fileURLWithPath:) はアプリバンドルのような directory を末尾 "/" 付きで正規化するため、
        // 期待値も同じ経路で作って比較する（生文字列比較だと trailing slash の有無で誤って落ちる）。
        #expect(call.viewerURL == URL(fileURLWithPath: "/System/Applications/Preview.app"))
        #expect(call.fileURL == URL(fileURLWithPath: tempEPUB.path(percentEncoded: false)))
    }

    @Test("G54-S2b: EPUB の専用指定が実在しなければ、category 側ではなく専用指定側のエラーになる")
    @MainActor
    func epubUsesItsOwnViewerNotCategoryOverride() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let calls = RecordedCalls()
        let originalLaunch = HelperLauncher.launch
        defer { HelperLauncher.launch = originalLaunch }
        HelperLauncher.launch = recordingLaunch(into: calls)
        let settings = ViewerSettings(defaults: suite)
        // .text の category override は実在するアプリにしておく
        settings.categoryViewerPaths[.text] = "/System/Applications/TextEdit.app"
        // EPUB 専用指定だけを実在しないパスにする
        let missingViewerPath = "/Applications/NoSuchApp\(UUID().uuidString).app"
        settings.epubViewerAppPath = missingViewerPath
        let tempEPUB = FileManager.default.temporaryDirectory
            .appending(path: "HelperLauncher-\(UUID().uuidString).epub")
        try Data().write(to: tempEPUB)
        defer { try? FileManager.default.removeItem(at: tempEPUB) }
        let book = makeBook(path: tempEPUB.path(percentEncoded: false), coverPath: "")
        let err = HelperLauncher.open(book: book, settings: settings)
        guard let err else {
            Issue.record("Expected non-nil AppError, got nil")
            return
        }
        if case let .launchFailed(_, reason) = err {
            // category override（実在する TextEdit）ではなく、専用指定（実在しないパス）が
            // 選ばれていることが、このエラーメッセージ（専用指定のパスを含む）で分かる。
            #expect(reason.contains("外部ビューアが見つかりません"))
            #expect(reason.contains(missingViewerPath))
        } else {
            Issue.record("Expected .launchFailed, got \(err)")
        }
        #expect(calls.entries.isEmpty)  // viewer 実体不在で弾かれているので launch には到達しない
    }

    @Test @MainActor
    func errorMessageMentionsFolderCategory() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let calls = RecordedCalls()
        let originalLaunch = HelperLauncher.launch
        defer { HelperLauncher.launch = originalLaunch }
        HelperLauncher.launch = recordingLaunch(into: calls)
        let settings = ViewerSettings(defaults: suite)
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "HelperLauncher-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let book = makeBook(path: tempDir.path(percentEncoded: false), coverPath: "")
        let err = HelperLauncher.open(book: book, settings: settings)
        guard let err, case let .launchFailed(_, reason) = err else {
            Issue.record("Expected .launchFailed")
            return
        }
        #expect(reason.contains("フォルダ"))
        #expect(calls.entries.isEmpty)  // viewer 未設定で弾かれているので launch には到達しない
    }
}
