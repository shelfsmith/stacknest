// SPDX-License-Identifier: MIT
import Foundation
import Testing
import EPUBAdapter
@testable import AppCore

@Suite("G56-S3: EPUB の書体と背景色の設定")
@MainActor
struct ViewerSettingsEPUBAppearanceTests {
    private func freshDefaults() -> UserDefaults {
        let name = "G56-S3-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsAreStandard() {
        let s = ViewerSettings(defaults: freshDefaults())
        #expect(s.epubFontFamily == nil)
        #expect(s.epubLightPalette == .standard)
        #expect(s.epubDarkPalette == .standard)
        #expect(s.epubForcesReadableColors == false)
        #expect(s.epubAppearance == EPUBAppearanceValue())
    }

    @Test func persistsAndReloads() {
        let d = freshDefaults()
        let s = ViewerSettings(defaults: d)
        s.epubFontFamily = "Hiragino Mincho ProN"
        s.epubLightPalette = .sepia
        s.epubDarkPalette = .navy
        s.epubForcesReadableColors = true
        s.epubTheme = .dark
        let r = ViewerSettings(defaults: d)
        #expect(r.epubAppearance == EPUBAppearanceValue(theme: .dark, lightPalette: .sepia, darkPalette: .navy,
                                                        fontFamily: "Hiragino Mincho ProN", forcesReadableColors: true))
        r.epubFontFamily = nil
        #expect(d.object(forKey: "epubFontFamily") == nil)
        #expect(ViewerSettings(defaults: d).epubFontFamily == nil)
    }

    @Test func unknownStoredValuesFallBackToStandard() {
        let d = freshDefaults()
        d.set("magenta", forKey: "epubLightPalette")
        d.set(42, forKey: "epubDarkPalette")
        d.set("", forKey: "epubFontFamily")
        let s = ViewerSettings(defaults: d)
        #expect(s.epubLightPalette == .standard)
        #expect(s.epubDarkPalette == .standard)
        #expect(s.epubFontFamily == nil)
    }

    @Test func changesPostPresentationNotification() {
        let s = ViewerSettings(defaults: freshDefaults())
        var count = 0
        let o = NotificationCenter.default.addObserver(forName: .viewerEPUBPresentationChanged, object: nil, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(o) }
        s.epubTheme = .dark
        s.epubFontFamily = "YuMincho"
        s.epubLightPalette = .cream
        s.epubDarkPalette = .charcoal
        s.epubForcesReadableColors = true
        #expect(count == 5)
    }
}
