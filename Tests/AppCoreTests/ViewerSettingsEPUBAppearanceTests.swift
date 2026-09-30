// SPDX-License-Identifier: MIT
import Foundation
import Testing
import EPUBAdapter
@testable import AppCore

@Suite("G56/G57: EPUB の書体・背景色・ホイールの設定")
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
        #expect(s.epubJapaneseFontFamily == nil)
        #expect(s.epubLatinFontFamily == nil)
        #expect(s.epubLightPalette == .standard)
        #expect(s.epubDarkPalette == .standard)
        #expect(s.epubForcesReadableColors == false)
        #expect(s.epubAppearance == EPUBAppearanceValue())
    }

    @Test func persistsAndReloads() {
        let d = freshDefaults()
        let s = ViewerSettings(defaults: d)
        s.epubJapaneseFontFamily = "Hiragino Mincho ProN"
        s.epubLatinFontFamily = "Georgia"
        s.epubLightPalette = .sepia
        s.epubDarkPalette = .navy
        s.epubForcesReadableColors = true
        s.epubTheme = .dark
        let r = ViewerSettings(defaults: d)
        #expect(r.epubAppearance == EPUBAppearanceValue(theme: .dark, lightPalette: .sepia, darkPalette: .navy,
                                                        japaneseFontFamily: "Hiragino Mincho ProN",
                                                        latinFontFamily: "Georgia", forcesReadableColors: true))
        r.epubJapaneseFontFamily = nil
        #expect(d.object(forKey: "epubJapaneseFontFamily") == nil)
        #expect(ViewerSettings(defaults: d).epubJapaneseFontFamily == nil)
    }

    @Test func unknownStoredValuesFallBackToStandard() {
        let d = freshDefaults()
        d.set("magenta", forKey: "epubLightPalette")
        d.set(42, forKey: "epubDarkPalette")
        d.set("", forKey: "epubJapaneseFontFamily")
        d.set("", forKey: "epubLatinFontFamily")
        let s = ViewerSettings(defaults: d)
        #expect(s.epubLightPalette == .standard)
        #expect(s.epubDarkPalette == .standard)
        #expect(s.epubJapaneseFontFamily == nil)
        #expect(s.epubLatinFontFamily == nil)
    }

    @Test func migratesG56FontFamily() {
        let d = freshDefaults()
        d.set("YuMincho", forKey: "epubFontFamily")
        let s = ViewerSettings(defaults: d)
        #expect(s.epubJapaneseFontFamily == "YuMincho")
        #expect(d.object(forKey: "epubFontFamily") == nil)
        #expect(d.string(forKey: "epubJapaneseFontFamily") == "YuMincho")
        #expect(ViewerSettings(defaults: d).epubJapaneseFontFamily == "YuMincho")
    }

    @Test func doesNotOverwriteExistingJapanese() {
        let d = freshDefaults()
        d.set("YuMincho", forKey: "epubFontFamily")
        d.set("Hiragino Sans", forKey: "epubJapaneseFontFamily")
        let s = ViewerSettings(defaults: d)
        #expect(s.epubJapaneseFontFamily == "Hiragino Sans")
        // 旧キーは和文キーが既にあっても消す（残すと「本の指定」を選んだ後に蘇る）。
        #expect(d.object(forKey: "epubFontFamily") == nil)
        s.epubJapaneseFontFamily = nil
        #expect(d.object(forKey: "epubJapaneseFontFamily") == nil)
        #expect(ViewerSettings(defaults: d).epubJapaneseFontFamily == nil)
    }

    @Test func removesEmptyLegacyFontFamily() {
        let d = freshDefaults()
        d.set("", forKey: "epubFontFamily")
        #expect(ViewerSettings(defaults: d).epubJapaneseFontFamily == nil)
        #expect(d.object(forKey: "epubFontFamily") == nil)
    }

    @Test func customColorsPersistAndBrokenFallsBack() {
        let d = freshDefaults()
        let s = ViewerSettings(defaults: d)
        s.epubDarkPalette = .custom
        s.epubDarkCustomColors = EPUBPaletteColors(background: EPUBRGB(hex: 0x102030), text: EPUBRGB(hex: 0xE0E0E0))
        #expect(d.string(forKey: "epubDarkCustomBackground") == "#102030")
        let r = ViewerSettings(defaults: d)
        #expect(r.epubAppearance.darkCustom?.text == EPUBRGB(hex: 0xE0E0E0))
        d.set("oops", forKey: "epubDarkCustomText")
        #expect(ViewerSettings(defaults: d).epubDarkCustomColors == nil)
    }

    @Test func ensureCustomColorsSeedsFromCurrentPreset() {
        let s = ViewerSettings(defaults: freshDefaults())
        s.epubLightPalette = .sepia
        s.ensureCustomColors(dark: false)
        #expect(s.epubLightCustomColors == EPUBLightPalette.sepia.colors)
        s.ensureCustomColors(dark: true)   // ダークは標準 → Washi の既定色
        #expect(s.epubDarkCustomColors == EPUBWashiDefaultColors.dark)
        s.epubLightCustomColors = EPUBPaletteColors(background: EPUBRGB(hex: 0x111111), text: EPUBRGB(hex: 0xEEEEEE))
        s.ensureCustomColors(dark: false)   // 既にあれば変えない
        #expect(s.epubLightCustomColors?.background == EPUBRGB(hex: 0x111111))
    }

    @Test func wheelDefaultsAndPersist() {
        let d = freshDefaults()
        let s = ViewerSettings(defaults: d)
        #expect(s.wheelTurnsPages == true)
        #expect(s.horizontalWheelTurnsPages == true)
        #expect(s.reversesHorizontalWheelTurn == false)
        s.wheelTurnsPages = false
        s.horizontalWheelTurnsPages = false
        s.reversesHorizontalWheelTurn = true
        let r = ViewerSettings(defaults: d)
        #expect(r.wheelTurnsPages == false)
        #expect(r.horizontalWheelTurnsPages == false && r.reversesHorizontalWheelTurn == true)
    }

    /// G59: 横方向の 2 設定は名前を変えたが、保存のキーは G57 のまま（今の値を引き継ぐ）。
    @Test func horizontalWheelSettingsKeepTheirG57Keys() {
        let d = freshDefaults()
        d.set(false, forKey: "epubHorizontalWheelTurnsPages")
        d.set(true, forKey: "epubReversesHorizontalWheelTurn")
        let s = ViewerSettings(defaults: d)
        #expect(s.horizontalWheelTurnsPages == false)
        #expect(s.reversesHorizontalWheelTurn == true)
        #expect(d.object(forKey: "wheelTurnsPages") == nil, "新設のキーは書くまで無い")
        s.wheelTurnsPages = false
        #expect(d.object(forKey: "wheelTurnsPages") as? Bool == false)
    }

    @Test func changesPostPresentationNotification() {
        let s = ViewerSettings(defaults: freshDefaults())
        var count = 0
        let o = NotificationCenter.default.addObserver(forName: .viewerEPUBPresentationChanged, object: nil, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(o) }
        s.epubTheme = .dark
        s.epubJapaneseFontFamily = "YuMincho"
        s.epubLatinFontFamily = "Georgia"
        s.epubLightPalette = .cream
        s.epubDarkPalette = .charcoal
        s.epubLightCustomColors = EPUBPaletteColors(background: EPUBRGB(hex: 0x111111), text: EPUBRGB(hex: 0xEEEEEE))
        s.epubDarkCustomColors = EPUBPaletteColors(background: EPUBRGB(hex: 0x102030), text: EPUBRGB(hex: 0xE0E0E0))
        s.epubForcesReadableColors = true
        s.horizontalWheelTurnsPages = false
        s.reversesHorizontalWheelTurn = true
        s.wheelTurnsPages = false
        #expect(count == 11)
    }
}
