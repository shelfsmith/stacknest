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

@Suite("G57: 欧文の書体をラテン文字の範囲に限る")
struct EPUBAppearanceCSSLatinRangeTests {
    private let fontSel = "body, body *:not(code):not(pre):not(kbd):not(samp)"
    private let faces = [
        EPUBFontFace(postScriptName: "Georgia", weight: 400, italic: false),
        EPUBFontFace(postScriptName: "Georgia-Italic", weight: 400, italic: true),
        EPUBFontFace(postScriptName: "Georgia-Bold", weight: 700, italic: false),
    ]

    @Test func bothWithFacesEmitsFontFacesAndAlias() throws {
        let css = try #require(EPUBAppearanceCSS.make(
            EPUBAppearanceValue(japaneseFontFamily: "YuMincho", latinFontFamily: "Georgia"),
            systemIsDark: false, latinFaces: faces))
        let lines = css.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "@font-face { font-family: \"StackNest Latin\"; src: local(\"Georgia\"); font-weight: 400; font-style: normal; unicode-range: U+0000-024F, U+1E00-1EFF; }")
        #expect(lines[1] == "@font-face { font-family: \"StackNest Latin\"; src: local(\"Georgia-Italic\"); font-weight: 400; font-style: italic; unicode-range: U+0000-024F, U+1E00-1EFF; }")
        #expect(lines[2].contains("local(\"Georgia-Bold\"); font-weight: 700; font-style: normal;"))
        #expect(lines.filter { $0.hasPrefix("@font-face") }.allSatisfy { $0.contains("unicode-range: U+0000-024F, U+1E00-1EFF;") })
        #expect(lines[3] == "\(fontSel) { font-family: \"StackNest Latin\", \"YuMincho\", serif !important; }")
    }
    @Test func latinOnlyWithFaces() throws {
        let css = try #require(EPUBAppearanceCSS.make(EPUBAppearanceValue(latinFontFamily: "Georgia"),
                                                      systemIsDark: false, latinFaces: faces))
        #expect(css.hasSuffix("\(fontSel) { font-family: \"StackNest Latin\", serif !important; }"))
        #expect(css.components(separatedBy: "@font-face").count - 1 == 3)
    }
    @Test func emptyFacesKeepsFamilyName() {
        let css = EPUBAppearanceCSS.make(EPUBAppearanceValue(japaneseFontFamily: "YuMincho", latinFontFamily: "Georgia"),
                                         systemIsDark: false, latinFaces: [])
        #expect(css == "\(fontSel) { font-family: \"Georgia\", \"YuMincho\", serif !important; }")
    }
    @Test func facesIgnoredWithoutLatinFamily() {
        let css = EPUBAppearanceCSS.make(EPUBAppearanceValue(japaneseFontFamily: "YuMincho"),
                                         systemIsDark: false, latinFaces: faces)
        #expect(css == "\(fontSel) { font-family: \"YuMincho\", serif !important; }")
    }
    @Test func escapesPostScriptNames() throws {
        let css = try #require(EPUBAppearanceCSS.make(
            EPUBAppearanceValue(latinFontFamily: "X"), systemIsDark: false,
            latinFaces: [EPUBFontFace(postScriptName: "A\"B\\C\nD", weight: 400, italic: false)]))
        #expect(css.contains("src: local(\"A\\\"B\\\\CD\");"))
    }
    @Test func fontFacesThenFontThenColor() throws {
        let custom = EPUBPaletteColors(background: EPUBRGB(hex: 0xFFFFFF), text: EPUBRGB(hex: 0x333333))
        let a = EPUBAppearanceValue(theme: .light, lightPalette: .custom, lightCustom: custom,
                                    latinFontFamily: "Georgia", forcesReadableColors: true)
        let lines = try #require(EPUBAppearanceCSS.make(a, systemIsDark: false, latinFaces: [faces[0]]))
            .split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("@font-face"))
        #expect(lines[1].contains("font-family: \"StackNest Latin\", serif"))
        #expect(lines[2].contains("color: #333333"))
    }
}
