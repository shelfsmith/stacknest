// SPDX-License-Identifier: MIT
import AppKit
import Testing
import Washi
import EPUBAdapter
@testable import WashiEPUBAdapter

@Suite("G57: 欧文の書体の字体を引き、ラテン文字の範囲に限る")
@MainActor
struct WashiLatinFaceTests {
    @Test func appKitWeightMapsToCSS() {
        let table: [(Int, Int)] = [(0, 100), (1, 100), (2, 100), (3, 200), (4, 300), (5, 400), (6, 500),
                                   (7, 600), (8, 600), (9, 700), (10, 700), (11, 800), (12, 800),
                                   (13, 900), (14, 900), (15, 900)]
        for (appKit, css) in table {
            #expect(WashiReaderHost.cssWeight(appKitWeight: appKit) == css, "AppKit \(appKit)")
        }
    }

    @Test func membersMapToFaces() {
        let italic = Int(NSFontTraitMask.italicFontMask.rawValue)
        let members: [[Any]] = [
            ["Georgia", "Regular", NSNumber(value: 5), NSNumber(value: 0)],
            ["Georgia-Italic", "Italic", NSNumber(value: 5), NSNumber(value: italic)],
            ["Georgia-Bold", "Bold", NSNumber(value: 9), NSNumber(value: Int(NSFontTraitMask.boldFontMask.rawValue))],
            ["broken"],   // 形の崩れた項目は捨てる
        ]
        #expect(WashiReaderHost.latinFaces(fromMembers: members) == [
            EPUBFontFace(postScriptName: "Georgia", weight: 400, italic: false),
            EPUBFontFace(postScriptName: "Georgia-Italic", weight: 400, italic: true),
            EPUBFontFace(postScriptName: "Georgia-Bold", weight: 700, italic: false),
        ])
    }

    @Test func applyAppearanceUsesResolvedFaces() {
        let host = WashiReaderHost()
        host.systemIsDark = { false }
        var asked: [String] = []
        host.resolveLatinFaces = { family in
            asked.append(family)
            return [EPUBFontFace(postScriptName: "Georgia-Bold", weight: 700, italic: false)]
        }
        host.applyAppearance(EPUBAppearanceValue(japaneseFontFamily: "YuMincho", latinFontFamily: "Georgia"))
        let css = host.reader.settings.userCSS ?? ""
        #expect(asked == ["Georgia"])
        #expect(css.contains("@font-face { font-family: \"StackNest Latin\"; src: local(\"Georgia-Bold\"); font-weight: 700;"))
        #expect(css.contains("unicode-range: U+0000-024F, U+1E00-1EFF;"))
        #expect(css.contains("font-family: \"StackNest Latin\", \"YuMincho\", serif !important;"))
    }

    @Test func resolverNotAskedWithoutLatinFamily() {
        let host = WashiReaderHost()
        host.systemIsDark = { false }
        var asked = 0
        host.resolveLatinFaces = { _ in asked += 1; return [] }
        host.applyAppearance(EPUBAppearanceValue(japaneseFontFamily: "YuMincho"))
        #expect(asked == 0)
        #expect(host.reader.settings.userCSS?.contains("\"YuMincho\", serif") == true)
    }

    @Test func unresolvedFamilyFallsBackToName() {
        let host = WashiReaderHost()
        host.systemIsDark = { false }
        host.resolveLatinFaces = { _ in [] }
        host.applyAppearance(EPUBAppearanceValue(latinFontFamily: "NoSuchFont"))
        #expect(host.reader.settings.userCSS?.contains("@font-face") == false)
        #expect(host.reader.settings.userCSS?.contains("\"NoSuchFont\", serif") == true)
    }

    /// 既定の解決器（NSFontManager）が、この機に入っている Georgia の字体を引けること。
    @Test func defaultResolverFindsGeorgiaFaces() {
        let host = WashiReaderHost()
        let faces = host.resolveLatinFaces("Georgia")
        #expect(faces.count >= 2)
        #expect(faces.contains { $0.weight == 400 && !$0.italic })
        #expect(faces.contains { $0.italic })
        #expect(host.resolveLatinFaces("NoSuchFont-\(UUID().uuidString)").isEmpty)
    }
}
