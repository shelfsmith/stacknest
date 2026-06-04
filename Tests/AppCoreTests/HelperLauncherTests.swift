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
            #expect(reason.contains("外部ビューワが見つかりません"))
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
