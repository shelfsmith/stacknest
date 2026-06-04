// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite struct ViewerSettingsTests {
    @Test @MainActor
    func defaultIsNil() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        #expect(settings.externalViewerAppPath == nil)
    }

    @Test @MainActor
    func setPersists() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let settings = ViewerSettings(defaults: suite)
        settings.externalViewerAppPath = "/Applications/cooViewer.app"

        // Re-instantiate to confirm persistence via UserDefaults
        let settings2 = ViewerSettings(defaults: suite)
        #expect(settings2.externalViewerAppPath == "/Applications/cooViewer.app")
    }

    @Test @MainActor
    func setNilClears() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        settings.externalViewerAppPath = "/Applications/cooViewer.app"
        settings.externalViewerAppPath = nil
        let settings2 = ViewerSettings(defaults: suite)
        #expect(settings2.externalViewerAppPath == nil)
    }

    @Test @MainActor
    func categoryViewerPathsDefaultEmpty() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        #expect(settings.categoryViewerPaths.isEmpty)
    }

    @Test @MainActor
    func categoryViewerPathsPersists() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        settings.categoryViewerPaths[.archive] = "/Applications/ArchiveApp.app"
        settings.categoryViewerPaths[.image] = "/Applications/ImageApp.app"

        let settings2 = ViewerSettings(defaults: suite)
        #expect(settings2.categoryViewerPaths[.archive] == "/Applications/ArchiveApp.app")
        #expect(settings2.categoryViewerPaths[.image] == "/Applications/ImageApp.app")
        #expect(settings2.categoryViewerPaths[.folder] == nil)
    }

    @Test @MainActor
    func categoryViewerPathsEmptyDictRemovesKey() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        settings.categoryViewerPaths[.archive] = "/Applications/A.app"
        settings.categoryViewerPaths = [:]

        let settings2 = ViewerSettings(defaults: suite)
        #expect(settings2.categoryViewerPaths.isEmpty)
    }

    @Test @MainActor
    func resolvedViewerPathUsesCategoryOverride() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        settings.externalViewerAppPath = "/Applications/Default.app"
        settings.categoryViewerPaths[.archive] = "/Applications/ArchiveOverride.app"
        #expect(settings.resolvedViewerPath(for: .archive) == "/Applications/ArchiveOverride.app")
    }

    @Test @MainActor
    func resolvedViewerPathFallsBackToDefault() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        settings.externalViewerAppPath = "/Applications/Default.app"
        // category override 未設定 → default に fallback
        #expect(settings.resolvedViewerPath(for: .image) == "/Applications/Default.app")
        #expect(settings.resolvedViewerPath(for: .folder) == "/Applications/Default.app")
    }

    @Test @MainActor
    func resolvedViewerPathReturnsNilWhenBothUnset() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        // 全て nil
        #expect(settings.resolvedViewerPath(for: .archive) == nil)
    }

    @Test @MainActor
    func categoryViewerPathsEncodesAsJSONObject() throws {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let settings = ViewerSettings(defaults: suite)
        settings.categoryViewerPaths[.archive] = "/Applications/A.app"
        settings.categoryViewerPaths[.image] = "/Applications/I.app"

        // Inspect raw bytes — must be JSON object {"archive":"/...","image":"/..."}
        // rather than unkeyed array ["archive","/...","image","/..."].
        let data = try #require(suite.data(forKey: "categoryViewerPaths"))
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"archive\":"))
        #expect(json.contains("\"image\":"))
        #expect(!json.hasPrefix("["))
        #expect(json.hasPrefix("{"))
    }
}
