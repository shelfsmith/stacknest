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

    @Test("G54-S2: EPUB 側のキーが無いときは画像側の値を写す（true）")
    @MainActor
    func epubSwitchSeedsFromImageWhenTrue() {
        let suite = UserDefaults(suiteName: "g54s2-seed-true-\(UUID().uuidString)")!
        suite.set(true, forKey: "useBuiltInViewer")
        let s = ViewerSettings(defaults: suite)
        #expect(s.useBuiltInImageViewer == true)
        #expect(s.useBuiltInEPUBViewer == true)
        #expect(suite.object(forKey: "useBuiltInEPUBViewer") != nil)
    }

    @Test("G54-S2: EPUB 側のキーが無いときは画像側の値を写す（false）")
    @MainActor
    func epubSwitchSeedsFromImageWhenFalse() {
        let suite = UserDefaults(suiteName: "g54s2-seed-false-\(UUID().uuidString)")!
        suite.set(false, forKey: "useBuiltInViewer")
        let s = ViewerSettings(defaults: suite)
        #expect(s.useBuiltInImageViewer == false)
        #expect(s.useBuiltInEPUBViewer == false, "外部を選んでいた人が EPUB だけ内蔵に戻らないこと")
    }

    @Test("G54-S2: 両方のキーが無いときは両方 true")
    @MainActor
    func bothDefaultTrueOnFirstRun() {
        let suite = UserDefaults(suiteName: "g54s2-firstrun-\(UUID().uuidString)")!
        let s = ViewerSettings(defaults: suite)
        #expect(s.useBuiltInImageViewer == true)
        #expect(s.useBuiltInEPUBViewer == true)
    }

    @Test("G54-S2: 一度写したら画像側を変えても EPUB 側は追従しない")
    @MainActor
    func epubSwitchDoesNotFollowAfterSeeding() {
        let name = "g54s2-independent-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.set(true, forKey: "useBuiltInViewer")
        _ = ViewerSettings(defaults: suite)          // ここで EPUB 側が true で書かれる
        suite.set(false, forKey: "useBuiltInViewer") // 画像側だけ外部にする
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.useBuiltInImageViewer == false)
        #expect(s2.useBuiltInEPUBViewer == true)
    }

    @Test("G54-S2: EPUB 側の変更が永続化される")
    @MainActor
    func epubSwitchPersists() {
        let name = "g54s2-persist-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let s = ViewerSettings(defaults: suite)
        s.useBuiltInEPUBViewer = false
        #expect(suite.bool(forKey: "useBuiltInEPUBViewer") == false)
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.useBuiltInEPUBViewer == false)
    }
}

@Suite("ViewerSettings allowMultipleViewerWindows")
struct ViewerSettingsAllowMultipleTests {
    @Test @MainActor func defaultsFalseAndPersists() {
        let suite = UserDefaults(suiteName: "g15-\(UUID().uuidString)")!
        let s = ViewerSettings(defaults: suite)
        #expect(s.allowMultipleViewerWindows == false)          // 既定 OFF
        s.allowMultipleViewerWindows = true
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.allowMultipleViewerWindows == true)          // persist
    }
}
