// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ViewerSettingsBuiltIn")
struct ViewerSettingsBuiltInTests {
    private func freshSuite() -> (UserDefaults, String) {
        let name = "test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test @MainActor func defaultsAreBuiltInRightToLeftStop() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        #expect(s.useBuiltInViewer == true)
        #expect(s.pageDirection == .rightToLeft)
        #expect(s.endOfBookBehavior == .stop)
    }

    @Test @MainActor func useBuiltInViewerPersists() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.useBuiltInViewer = false
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.useBuiltInViewer == false)
    }

    @Test @MainActor func pageDirectionPersists() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.pageDirection = .leftToRight
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.pageDirection == .leftToRight)
    }

    @Test @MainActor func endOfBookBehaviorPersists() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.endOfBookBehavior = .loop
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.endOfBookBehavior == .loop)
    }

    @Test @MainActor func viewerOptionsReflectsSettings() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.pageDirection = .leftToRight
        s.endOfBookBehavior = .nextBook
        let opts = s.viewerOptions
        #expect(opts.pageDirection == .leftToRight)
        #expect(opts.endOfBookBehavior == .nextBook)
    }

    // Phase 2.6b-2-3: tabSkipPageCount
    @Test @MainActor func tabSkipPageCountDefaultIs10() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        #expect(s.tabSkipPageCount == 10)
    }

    @Test @MainActor func tabSkipPageCountPersists() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.tabSkipPageCount = 25
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.tabSkipPageCount == 25)
    }

    @Test @MainActor func tabSkipPageCountClampsToRange() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.tabSkipPageCount = 0
        #expect(s.tabSkipPageCount == 1)
        s.tabSkipPageCount = 200
        #expect(s.tabSkipPageCount == 100)
    }

    // MARK: - T5 / T-S1: spreadByDefault (初期値 true に変更)

    /// Phase 2.6b-2 T-S1: 初回起動（key 不在）で spreadByDefault は true であること。
    @Test @MainActor func spreadByDefaultIsTrueOnFirstRun() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        #expect(s.spreadByDefault == true, "初回起動（key 不在）では見開きデフォルト ON であること")
    }

    @Test @MainActor func spreadByDefaultPersists() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.spreadByDefault = true
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.spreadByDefault == true)
    }

    /// 明示的に false を保存した場合は false が読み出されること（初期値 true とは独立）。
    @Test @MainActor func spreadByDefaultExplicitFalsePersists() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.spreadByDefault = false
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.spreadByDefault == false, "明示的な false は初期値 true とは独立して保持されること")
    }

    @Test @MainActor func spreadByDefaultRoundtripsToFalse() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.spreadByDefault = true
        s.spreadByDefault = false
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.spreadByDefault == false)
    }

    // MARK: - T-F1: openFullScreenByDefault

    /// Phase 2.6b-2 T-F1: 初回起動（key 不在）で openFullScreenByDefault は false であること。
    @Test @MainActor func openFullScreenByDefaultIsFalseOnFirstRun() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        #expect(s.openFullScreenByDefault == false, "初回起動（key 不在）では全画面起動はデフォルト OFF であること")
    }

    @Test @MainActor func openFullScreenByDefaultPersistsTrue() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.openFullScreenByDefault = true
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.openFullScreenByDefault == true)
    }

    @Test @MainActor func openFullScreenByDefaultPersistsFalse() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.openFullScreenByDefault = true
        s.openFullScreenByDefault = false
        let s2 = ViewerSettings(defaults: suite)
        #expect(s2.openFullScreenByDefault == false)
    }
}
