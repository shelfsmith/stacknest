// SPDX-License-Identifier: MIT
import AppKit
import Testing
import WashiCore
import Washi
import EPUBAdapter
@testable import WashiEPUBAdapter

@Suite("G56-S3: 見た目の設定の Washi への写し替え")
@MainActor
struct WashiAppearanceTests {
    @Test func standardAppearanceKeepsWashiDefaults() {
        let host = WashiReaderHost()
        host.systemIsDark = { false }
        host.applyAppearance(EPUBAppearanceValue())
        let s = host.reader.settings
        #expect(s.theme == .system)
        #expect(s.backgroundColor == nil && s.textColor == nil)
        #expect(s.fontFamilyOverride == nil)
        #expect(s.userCSS == nil)
        #expect(s.forcesReadableColors == false)
    }

    @Test func mapsPaletteFontAndReadable() {
        let host = WashiReaderHost()
        host.systemIsDark = { false }
        host.applyAppearance(EPUBAppearanceValue(theme: .light, lightPalette: .sepia, darkPalette: .navy,
                                                 japaneseFontFamily: "YuMincho", forcesReadableColors: false))
        let s = host.reader.settings
        #expect(s.theme == .light)
        #expect(s.backgroundColor == EPUBRGBAColor(r: 0xF4 / 255.0, g: 0xEC / 255.0, b: 0xD8 / 255.0))
        #expect(s.textColor == EPUBRGBAColor(r: 0x5B / 255.0, g: 0x46 / 255.0, b: 0x36 / 255.0))
        #expect(s.fontFamilyOverride == nil)
        #expect(s.userCSS?.contains("\"YuMincho\", serif") == true)
        host.applyAppearance(EPUBAppearanceValue(theme: .light, lightPalette: .sepia, forcesReadableColors: true))
        #expect(host.reader.settings.textColor == nil)
        #expect(host.reader.settings.forcesReadableColors == true)
        #expect(host.reader.settings.fontFamilyOverride == nil)
        #expect(host.reader.settings.userCSS == nil)
    }

    @Test func systemThemeFollowsAppearanceChange() {
        let host = WashiReaderHost()
        var dark = false
        host.systemIsDark = { dark }
        host.increaseContrast = { false }
        host.applyAppearance(EPUBAppearanceValue(theme: .system, lightPalette: .cream, darkPalette: .charcoal))
        #expect(host.reader.settings.backgroundColor == EPUBRGBAColor(r: 0xF7 / 255.0, g: 0xF1 / 255.0, b: 0xE3 / 255.0))
        dark = true
        host.refreshAppearanceForSystemChange()
        #expect(host.reader.settings.backgroundColor == EPUBRGBAColor(r: 0x2B / 255.0, g: 0x2B / 255.0, b: 0x2D / 255.0))
    }

    @Test func userCSSCarriesFontsAndForcedColor() {
        let host = WashiReaderHost()
        host.systemIsDark = { false }
        host.increaseContrast = { false }   // 実機の「コントラストを上げる」に依存しない
        host.resolveLatinFaces = { _ in [] }   // 字体が引けない経路（書体名の並び）。別名の経路は WashiLatinFaceTests
        let custom = EPUBPaletteColors(background: EPUBRGB(hex: 0xFFFFFF), text: EPUBRGB(hex: 0x333333))
        host.applyAppearance(EPUBAppearanceValue(theme: .light, lightPalette: .custom, lightCustom: custom,
                                                 japaneseFontFamily: "YuMincho", latinFontFamily: "Georgia",
                                                 forcesReadableColors: true))
        let s = host.reader.settings
        #expect(s.fontFamilyOverride == nil)
        #expect(s.userCSS?.contains("\"Georgia\", \"YuMincho\", serif") == true)
        #expect(s.userCSS?.contains("color: #333333 !important") == true)
        #expect(s.forcesReadableColors == true)
        #expect(s.textColor == nil)
        #expect(s.backgroundColor == EPUBRGBAColor(r: 1, g: 1, b: 1))
    }
    @Test func systemFlipChangesUserCSSAndCaptures() {
        let host = WashiReaderHost()
        var dark = false
        host.systemIsDark = { dark }
        host.increaseContrast = { false }
        var navs: [EPUBLocator] = []
        host.navigateReader = { navs.append($0) }
        host.fetchAnchoredLocator = { EPUBLocator(spineIndex: 0) }
        host.markLoadedForTesting()
        let l = EPUBPaletteColors(background: EPUBRGB(hex: 0xFFFFFF), text: EPUBRGB(hex: 0x111111))
        let d = EPUBPaletteColors(background: EPUBRGB(hex: 0x000000), text: EPUBRGB(hex: 0xEEEEEE))
        host.applyAppearance(EPUBAppearanceValue(lightPalette: .custom, darkPalette: .custom, lightCustom: l, darkCustom: d,
                                                 forcesReadableColors: true))
        host.go(to: EPUBLocatorValue(spine: 1, progress: 0.5, cfi: "washi:t=10;idref=c1", engine: "washi"))
        navs.removeAll()
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 1, progression: 0.5, idref: "c1"), pageInItem: 1, pageCountInItem: 3)
        dark = true
        host.refreshAppearanceForSystemChange()
        #expect(host.reader.settings.userCSS?.contains("#EEEEEE") == true)
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 1, progression: 0.45, idref: "c1"), pageInItem: 1, pageCountInItem: 4)
        #expect(navs.count == 1)
    }
    /// 復元のアンカーが載った状態を作る（G56 の非空振り版と同じ手順）。
    private func anchoredHost() -> (WashiReaderHost, () -> Int) {
        let host = WashiReaderHost()
        var navs: [EPUBLocator] = []
        host.navigateReader = { navs.append($0) }
        host.fetchAnchoredLocator = { EPUBLocator(spineIndex: 0) }
        host.systemIsDark = { false }
        host.markLoadedForTesting()
        host.go(to: EPUBLocatorValue(spine: 1, progress: 0.5, cfi: "washi:t=10;idref=c1", engine: "washi"))
        navs.removeAll()
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 1, progression: 0.5, idref: "c1"), pageInItem: 1, pageCountInItem: 3)
        #expect(host.lastPublished?.textOffset == 10)
        return (host, { navs.count })
    }
    @Test func colorOnlyPresetChangeDoesNotCapture() {
        let (host, navCount) = anchoredHost()
        host.applyAppearance(EPUBAppearanceValue(lightPalette: .cream))   // userCSS は nil のまま
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 1, progression: 0.6, idref: "c1"), pageInItem: 2, pageCountInItem: 3)
        #expect(navCount() == 0)
    }
    @Test func typefaceChangeCaptures() {
        let (host, navCount) = anchoredHost()
        host.applyAppearance(EPUBAppearanceValue(latinFontFamily: "Georgia"))   // userCSS が変わる
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 1, progression: 0.4, idref: "c1"), pageInItem: 1, pageCountInItem: 4)
        #expect(navCount() == 1)
    }
    /// G57（Codex P2）: 「コントラストを上げる」の間は Washi が背景と文字を純白／純黒に固定するので、
    /// 強制文字色の CSS は出さない（白地に白字を避ける）。書体は効かせる。
    @Test func increaseContrastDropsForcedColorButKeepsFonts() {
        let host = WashiReaderHost()
        host.systemIsDark = { true }
        host.increaseContrast = { true }
        host.resolveLatinFaces = { _ in [] }
        let d = EPUBPaletteColors(background: EPUBRGB(hex: 0x000000), text: EPUBRGB(hex: 0xFFFFFF))
        host.applyAppearance(EPUBAppearanceValue(theme: .dark, darkPalette: .custom, darkCustom: d,
                                                 japaneseFontFamily: "YuMincho", forcesReadableColors: true))
        let css = host.reader.settings.userCSS ?? ""
        #expect(css.contains("\"YuMincho\", serif"))
        #expect(!css.contains("color: #"))
    }

    /// 設定の切り替え（`accessibilityDisplayOptionsDidChangeNotification`）で当て直し、tearDown 後は聞かない。
    @Test func accessibilityDisplayChangeReappliesUntilTornDown() {
        let host = WashiReaderHost()
        host.systemIsDark = { false }
        var contrast = false
        var asked = 0
        host.increaseContrast = { asked += 1; return contrast }
        let l = EPUBPaletteColors(background: EPUBRGB(hex: 0xFFFFFF), text: EPUBRGB(hex: 0x111111))
        host.applyAppearance(EPUBAppearanceValue(theme: .light, lightPalette: .custom, lightCustom: l,
                                                 forcesReadableColors: true))
        #expect(host.reader.settings.userCSS?.contains("color: #111111") == true)
        let center = NSWorkspace.shared.notificationCenter
        contrast = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(host.reader.settings.userCSS == nil)
        contrast = false
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(host.reader.settings.userCSS?.contains("color: #111111") == true)
        host.tearDown()
        let before = asked
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(asked == before)
    }

    @Test func wheelSettingsMap() {
        let host = WashiReaderHost()
        host.horizontalWheelTurnsPages = false
        host.reversesHorizontalWheelTurn = true
        #expect(host.reader.settings.horizontalWheelTurnsPages == false)
        #expect(host.reader.settings.reversesHorizontalWheelTurn == true)
        host.wheelTurnsPages = false
        #expect(host.reader.settings.wheelTurnsPages == false)
    }
}
