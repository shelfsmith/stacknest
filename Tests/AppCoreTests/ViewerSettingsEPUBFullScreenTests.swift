// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

@Suite("G51: EPUB を全画面で開く設定")
struct ViewerSettingsEPUBFullScreenTests {
    private func freshDefaults() -> UserDefaults {
        let name = "g51-epub-fullscreen-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        return ud
    }
    @Test @MainActor
    func defaultIsOff() {
        let s = ViewerSettings(defaults: freshDefaults())
        #expect(s.openEPUBFullScreenByDefault == false)
    }
    @Test @MainActor
    func persistsAndReloads() {
        let ud = freshDefaults()
        let s = ViewerSettings(defaults: ud)
        s.openEPUBFullScreenByDefault = true
        #expect(ud.bool(forKey: "viewerOpenEPUBFullScreenByDefault") == true)
        #expect(ViewerSettings(defaults: ud).openEPUBFullScreenByDefault == true)
    }
    @Test @MainActor
    func independentFromImageViewerSetting() {
        let ud = freshDefaults()
        let s = ViewerSettings(defaults: ud)
        s.openFullScreenByDefault = true
        #expect(s.openEPUBFullScreenByDefault == false)
    }
}
