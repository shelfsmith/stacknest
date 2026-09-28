// SPDX-License-Identifier: MIT
import Testing
@testable import EPUBAdapter

@Suite("G56-S3: EPUB の配色の解決")
struct EPUBAppearanceTests {
    @Test func standardPalettesPassNothing() {
        let a = EPUBAppearanceValue()
        let light = a.resolvedColors(systemIsDark: false)
        let dark = a.resolvedColors(systemIsDark: true)
        #expect(light.background == nil && light.text == nil)
        #expect(dark.background == nil && dark.text == nil)
    }

    @Test(arguments: [EPUBReaderThemeValue.system, .light, .dark], [false, true])
    func picksPaletteByEffectiveTheme(theme: EPUBReaderThemeValue, systemIsDark: Bool) {
        let a = EPUBAppearanceValue(theme: theme, lightPalette: .sepia, darkPalette: .navy)
        let dark = theme == .dark || (theme == .system && systemIsDark)
        #expect(a.isDark(systemIsDark: systemIsDark) == dark)
        let c = a.resolvedColors(systemIsDark: systemIsDark)
        let expected = dark ? EPUBDarkPalette.navy.colors! : EPUBLightPalette.sepia.colors!
        #expect(c.background == expected.background)
        #expect(c.text == expected.text)
    }

    @Test func forcingReadableDropsTextColor() {
        let a = EPUBAppearanceValue(theme: .light, lightPalette: .cream, forcesReadableColors: true)
        let c = a.resolvedColors(systemIsDark: false)
        #expect(c.background == EPUBLightPalette.cream.colors!.background)
        #expect(c.text == nil)
    }

    @Test func paletteTextContrast() {
        let all = EPUBLightPalette.allCases.compactMap(\.colors) + EPUBDarkPalette.allCases.compactMap(\.colors)
        #expect(all.count == 4)
        for p in all { #expect(EPUBContrast.ratio(p.background, p.text) >= 4.5) }
    }

    /// Washi 1.22.0 の「読みやすさ優先」の文字色とリンク色（`EPUBReaderSettings.effectiveColors`／`composedUserCSS` の定数を写した）。
    @Test func washiReadableColorsContrastOnOurBackgrounds() {
        let lightText = EPUBRGB(hex: 0x1A1A1A), lightLink = EPUBRGB(hex: 0x1A56DB)
        let darkText = EPUBRGB(hex: 0xECECEC), darkLink = EPUBRGB(hex: 0x7FB2FF)
        for p in EPUBLightPalette.allCases.compactMap(\.colors) {
            #expect(EPUBContrast.ratio(p.background, lightText) >= 4.5)
            #expect(EPUBContrast.ratio(p.background, lightLink) >= 4.5)
        }
        for p in EPUBDarkPalette.allCases.compactMap(\.colors) {
            #expect(EPUBContrast.ratio(p.background, darkText) >= 4.5)
            #expect(EPUBContrast.ratio(p.background, darkLink) >= 4.5)
        }
    }

    @Test func contrastKnownValues() {
        #expect(abs(EPUBContrast.ratio(EPUBRGB(hex: 0xFFFFFF), EPUBRGB(hex: 0x000000)) - 21) < 0.01)
        #expect(abs(EPUBContrast.ratio(EPUBRGB(hex: 0x777777), EPUBRGB(hex: 0x777777)) - 1) < 0.001)
    }

    @Test func rawValuesAreStable() {
        #expect(EPUBLightPalette.allCases.map(\.rawValue) == ["standard", "cream", "sepia"])
        #expect(EPUBDarkPalette.allCases.map(\.rawValue) == ["standard", "charcoal", "navy"])
    }
}
