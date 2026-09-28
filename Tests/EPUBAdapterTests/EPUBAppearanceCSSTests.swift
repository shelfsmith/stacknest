// SPDX-License-Identifier: MIT
import Testing
@testable import EPUBAdapter

@Suite("G57: 書体と強制色の CSS")
struct EPUBAppearanceCSSTests {
    private let fontSel = "body, body *:not(code):not(pre):not(kbd):not(samp)"

    @Test func nothingByDefault() {
        #expect(EPUBAppearanceCSS.make(EPUBAppearanceValue(), systemIsDark: false) == nil)
    }
    @Test func bothFamiliesLatinFirst() {
        let css = EPUBAppearanceCSS.make(EPUBAppearanceValue(japaneseFontFamily: "YuMincho", latinFontFamily: "Georgia"), systemIsDark: false)
        #expect(css == "\(fontSel) { font-family: \"Georgia\", \"YuMincho\", serif !important; }")
    }
    @Test func japaneseOnly() {
        let css = EPUBAppearanceCSS.make(EPUBAppearanceValue(japaneseFontFamily: "YuMincho"), systemIsDark: false)
        #expect(css == "\(fontSel) { font-family: \"YuMincho\", serif !important; }")
    }
    @Test func latinOnly() {
        let css = EPUBAppearanceCSS.make(EPUBAppearanceValue(latinFontFamily: "Georgia"), systemIsDark: false)
        #expect(css == "\(fontSel) { font-family: \"Georgia\", serif !important; }")
    }
    @Test func emptyNamesAreIgnored() {
        #expect(EPUBAppearanceCSS.make(EPUBAppearanceValue(japaneseFontFamily: "", latinFontFamily: ""), systemIsDark: false) == nil)
    }
    @Test func escapesNames() {
        #expect(EPUBAppearanceCSS.escapedFamily("A\"B\\C\nD\u{2028}E") == "A\\\"B\\\\CDE")
    }
    @Test func forcedColorOnlyWhenCustomAndReadable() {
        let custom = EPUBPaletteColors(background: EPUBRGB(hex: 0x102030), text: EPUBRGB(hex: 0xE0E0E0))
        let on = EPUBAppearanceValue(theme: .dark, darkPalette: .custom, darkCustom: custom, forcesReadableColors: true)
        #expect(EPUBAppearanceCSS.make(on, systemIsDark: false)
                == "body, body *:not(a):not(a *):not(pre):not(code):not(pre *):not(code *) { color: #E0E0E0 !important; }")
        var off = on; off.forcesReadableColors = false
        #expect(EPUBAppearanceCSS.make(off, systemIsDark: false) == nil)
        var preset = on; preset.darkPalette = .navy
        #expect(EPUBAppearanceCSS.make(preset, systemIsDark: false) == nil)
    }
    @Test func fontThenColor() {
        let custom = EPUBPaletteColors(background: EPUBRGB(hex: 0xFFFFFF), text: EPUBRGB(hex: 0x333333))
        let a = EPUBAppearanceValue(theme: .light, lightPalette: .custom, lightCustom: custom,
                                    japaneseFontFamily: "YuMincho", forcesReadableColors: true)
        let lines = EPUBAppearanceCSS.make(a, systemIsDark: false)?.split(separator: "\n") ?? []
        #expect(lines.count == 2)
        #expect(lines.first?.contains("font-family") == true)
        #expect(lines.last?.contains("color: #333333") == true)
    }
}
