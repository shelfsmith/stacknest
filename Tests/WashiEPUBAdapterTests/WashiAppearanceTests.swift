// SPDX-License-Identifier: MIT
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
        #expect(s.forcesReadableColors == false)
    }

    @Test func mapsPaletteFontAndReadable() {
        let host = WashiReaderHost()
        host.systemIsDark = { false }
        host.applyAppearance(EPUBAppearanceValue(theme: .light, lightPalette: .sepia, darkPalette: .navy,
                                                 fontFamily: "YuMincho", forcesReadableColors: false))
        let s = host.reader.settings
        #expect(s.theme == .light)
        #expect(s.backgroundColor == EPUBRGBAColor(r: 0xF4 / 255.0, g: 0xEC / 255.0, b: 0xD8 / 255.0))
        #expect(s.textColor == EPUBRGBAColor(r: 0x5B / 255.0, g: 0x46 / 255.0, b: 0x36 / 255.0))
        #expect(s.fontFamilyOverride == "YuMincho")
        host.applyAppearance(EPUBAppearanceValue(theme: .light, lightPalette: .sepia, forcesReadableColors: true))
        #expect(host.reader.settings.textColor == nil)
        #expect(host.reader.settings.forcesReadableColors == true)
        #expect(host.reader.settings.fontFamilyOverride == nil)
    }

    @Test func systemThemeFollowsAppearanceChange() {
        let host = WashiReaderHost()
        var dark = false
        host.systemIsDark = { dark }
        host.applyAppearance(EPUBAppearanceValue(theme: .system, lightPalette: .cream, darkPalette: .charcoal))
        #expect(host.reader.settings.backgroundColor == EPUBRGBAColor(r: 0xF7 / 255.0, g: 0xF1 / 255.0, b: 0xE3 / 255.0))
        dark = true
        host.refreshAppearanceForSystemChange()
        #expect(host.reader.settings.backgroundColor == EPUBRGBAColor(r: 0x2B / 255.0, g: 0x2B / 255.0, b: 0x2D / 255.0))
    }

    @Test func fontChangeCapturesRelandTarget() {
        let host = WashiReaderHost()
        var navs: [EPUBLocator] = []
        host.navigateReader = { navs.append($0) }
        host.fetchAnchoredLocator = { EPUBLocator(spineIndex: 0) }
        host.systemIsDark = { false }
        host.markLoadedForTesting()
        host.go(to: EPUBLocatorValue(spine: 1, progress: 0.5, cfi: "washi:t=10;idref=c1", engine: "washi"))
        navs.removeAll()
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 1, progression: 0.5, idref: "c1"), pageInItem: 1, pageCountInItem: 3)
        host.applyAppearance(EPUBAppearanceValue(fontFamily: "YuGothic"))
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 1, progression: 0.4, idref: "c1"), pageInItem: 1, pageCountInItem: 4)
        #expect(navs.count == 1)
        // 色だけの変更では控えない
        host.applyAppearance(EPUBAppearanceValue(lightPalette: .cream, fontFamily: "YuGothic"))
        host.readerView(host.reader, didMoveTo: EPUBLocator(spineIndex: 1, progression: 0.45, idref: "c1"), pageInItem: 1, pageCountInItem: 4)
        #expect(navs.count == 1)
    }
}
