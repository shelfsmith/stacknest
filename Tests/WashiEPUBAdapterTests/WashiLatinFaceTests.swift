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

    private static func member(_ ps: String, _ face: String, _ w: Int, _ traits: Int) -> [Any] {
        [ps, face, NSNumber(value: w), NSNumber(value: traits)]
    }

    /// 同じ (太さ, 斜体) の字体が 2 つあると WebKit は後の方を使う。幅違い（Condensed など）を捨て、
    /// 残りは最初の字体（ファミリーの正規の並び）を採る。実機（2026-09-28）の並びをそのまま写した。
    @Test func helveticaNeueSkipsCondensedAndKeepsFirst() {
        let m = Self.member
        let members: [[Any]] = [
            m("HelveticaNeue", "Regular", 5, 0x0), m("HelveticaNeue-Italic", "Italic", 5, 0x1),
            m("HelveticaNeue-UltraLight", "UltraLight", 2, 0x0), m("HelveticaNeue-UltraLightItalic", "UltraLight Italic", 2, 0x1),
            m("HelveticaNeue-Thin", "Thin", 3, 0x10000), m("HelveticaNeue-ThinItalic", "Thin Italic", 3, 0x10001),
            m("HelveticaNeue-Light", "Light", 3, 0x0), m("HelveticaNeue-LightItalic", "Light Italic", 3, 0x1),
            m("HelveticaNeue-Medium", "Medium", 6, 0x0), m("HelveticaNeue-MediumItalic", "Medium Italic", 6, 0x1),
            m("HelveticaNeue-Bold", "Bold", 9, 0x2), m("HelveticaNeue-BoldItalic", "Bold Italic", 9, 0x3),
            m("HelveticaNeue-CondensedBold", "Condensed Bold", 9, 0x42),
            m("HelveticaNeue-CondensedBlack", "Condensed Black", 11, 0x42),
        ]
        let faces = WashiReaderHost.latinFaces(fromMembers: members)
        Self.expectUniqueAndUncondensed(faces)
        #expect(faces.first { $0.weight == 700 && !$0.italic }?.postScriptName == "HelveticaNeue-Bold")
        #expect(faces.first { $0.weight == 400 && !$0.italic }?.postScriptName == "HelveticaNeue")
        #expect(!faces.contains { $0.weight == 800 })   // Condensed Black しか無い太さは出さない
    }

    @Test func futuraSkipsCondensedMedium() {
        let m = Self.member
        let members: [[Any]] = [
            m("Futura-Medium", "Medium", 6, 0x0), m("Futura-MediumItalic", "Medium Italic", 6, 0x1),
            m("Futura-Bold", "Bold", 9, 0x2),
            m("Futura-CondensedMedium", "Condensed Medium", 6, 0x40),
            m("Futura-CondensedExtraBold", "Condensed ExtraBold", 11, 0x42),
        ]
        let faces = WashiReaderHost.latinFaces(fromMembers: members)
        Self.expectUniqueAndUncondensed(faces)
        #expect(faces.map(\.postScriptName) == ["Futura-Medium", "Futura-MediumItalic", "Futura-Bold"])
    }

    @Test func hoeflerTextKeepsRegularOverOrnaments() {
        let m = Self.member
        let members: [[Any]] = [
            m("HoeflerText-Regular", "Regular", 5, 0x0), m("HoeflerText-Ornaments", "Ornaments", 5, 0x0),
            m("HoeflerText-Italic", "Italic", 5, 0x1),
            m("HoeflerText-Black", "Black", 9, 0x2), m("HoeflerText-BlackItalic", "Black Italic", 9, 0x3),
        ]
        let faces = WashiReaderHost.latinFaces(fromMembers: members)
        Self.expectUniqueAndUncondensed(faces)
        #expect(faces.map(\.postScriptName) == ["HoeflerText-Regular", "HoeflerText-Italic",
                                                "HoeflerText-Black", "HoeflerText-BlackItalic"])
    }

    @Test func otherWidthTraitsAreSkipped() {
        let m = Self.member
        for trait in [0x10, 0x20, 0x40, 0x200] {   // narrow / expanded / condensed / compressed
            #expect(WashiReaderHost.latinFaces(fromMembers: [m("X-Wide", "Wide", 5, trait)]).isEmpty, "traits \(trait)")
        }
    }

    private static func expectUniqueAndUncondensed(_ faces: [EPUBFontFace]) {
        #expect(!faces.contains { $0.postScriptName.contains("Condensed") })
        let keys = faces.map { "\($0.weight)-\($0.italic)" }
        #expect(Set(keys).count == keys.count, "\(keys)")
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
