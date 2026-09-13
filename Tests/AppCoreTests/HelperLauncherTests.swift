// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import LibraryStore

@Suite struct HelperLauncherTests {
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

    @Test @MainActor
    func returnsErrorWhenViewerNotSet() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
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
    }

    @Test @MainActor
    func returnsErrorWhenBookHasNoPath() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
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
    }

    @Test @MainActor
    func returnsErrorWhenViewerMissing() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
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
    }

    @Test @MainActor
    func returnsErrorWhenFileMissing() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
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
    }

    @Test("G54-S2b: EPUB は専用指定のアプリで開く")
    @MainActor
    func epubUsesItsOwnViewer() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        // .text の category override を実在するアプリに設定 -- EPUB の専用指定に負けることを確かめたい対照
        settings.categoryViewerPaths[.text] = "/System/Applications/TextEdit.app"
        // EPUB 専用指定は実在するアプリにする -- こちらが選ばれれば起動エラーは出ない
        settings.epubViewerAppPath = "/System/Applications/Preview.app"
        let tempEPUB = FileManager.default.temporaryDirectory
            .appending(path: "HelperLauncher-\(UUID().uuidString).epub")
        try Data().write(to: tempEPUB)
        defer { try? FileManager.default.removeItem(at: tempEPUB) }
        let book = makeBook(path: tempEPUB.path(percentEncoded: false), coverPath: "")
        let err = HelperLauncher.open(book: book, settings: settings)
        // 専用指定（実在パス）が選ばれるので、起動は成功しエラーは返らない。
        // category override（TextEdit）が選ばれていたら同じく nil になってしまうため、これ単独では
        // 「専用指定が引かれた」証拠にならない -- 次のテストで専用指定側だけを壊して切り分ける。
        #expect(err == nil)
    }

    @Test("G54-S2b: EPUB の専用指定が実在しなければ、category 側ではなく専用指定側のエラーになる")
    @MainActor
    func epubUsesItsOwnViewerNotCategoryOverride() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
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
    }

    @Test @MainActor
    func errorMessageMentionsFolderCategory() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
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
    }
}
