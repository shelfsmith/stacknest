// SPDX-License-Identifier: MIT
import AppKit
import CoreText

/// G56-S3: EPUB の書体の候補 1 つ。`family` は保存値と Washi へ渡す CSS のファミリー名。
struct EPUBFontCandidate: Identifiable, Equatable {
    let family: String
    let displayName: String
    var id: String { family }
}

/// G56-S3/G57: macOS に標準で入る（またはダウンロードで入る）和文・欧文書体から、機械にあるものだけを候補にする。
enum EPUBFontCandidates {
    /// 表示順。2026-09-28 に母艦（macOS 26.6.2）で実在を確認したファミリー名。
    static let preferredJapaneseFamilies = [
        "Hiragino Mincho ProN", "Hiragino Sans", "Hiragino Maru Gothic ProN",
        "YuMincho", "YuGothic",
        "Toppan Bunkyu Mincho", "Toppan Bunkyu Gothic",
        "Tsukushi A Round Gothic", "Klee", "YuKyokasho",
        "BIZ UDMincho", "BIZ UDGothic",
    ]

    /// G57: 欧文の書体候補。表示順。2026-09-28 に母艦で実在を確認（`Iowan Old Style` は無いため外した）。
    static let preferredLatinFamilies = [
        "Baskerville", "Georgia", "Hoefler Text", "Palatino",
        "Charter", "Times New Roman", "Helvetica Neue", "Avenir Next",
    ]

    static func available(_ preferred: [String], installed: Set<String>, localizedName: (String) -> String) -> [EPUBFontCandidate] {
        preferred.filter(installed.contains).map { EPUBFontCandidate(family: $0, displayName: localizedName($0)) }
    }

    static func availableOnThisMac(_ preferred: [String]) -> [EPUBFontCandidate] {
        let fm = NSFontManager.shared
        return available(preferred, installed: Set(fm.availableFontFamilies),
                         localizedName: { fm.localizedName(forFamily: $0, face: nil) })
    }

    /// 保存した書体が機械に無ければ nil（＝本の指定に従う）。保存値は消さない。
    static func effectiveFamily(_ stored: String?, installed: Set<String>) -> String? {
        guard let stored, installed.contains(stored) else { return nil }
        return stored
    }

    static func effectiveFamilyOnThisMac(_ stored: String?) -> String? {
        effectiveFamily(stored, installed: Set(NSFontManager.shared.availableFontFamilies))
    }

    /// G57: 「あ」と「漢」の両方の字形を持つか。名前で作れず別の書体に置き換わったときは false。
    static func hasJapaneseGlyphs(family: String) -> Bool {
        let font = CTFontCreateWithName(family as CFString, 14, nil)
        guard (CTFontCopyFamilyName(font) as String) == family else { return false }

        let characters: [UniChar] = Array("あ漢".utf16) // l10n:ignore（字形の判定用の固定文字。画面には出さない）
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        return glyphs.allSatisfy { $0 != 0 }
    }

    /// G57: フォントパネルで選んだ書体・候補外の書体の表示名（`NSFontManager.localizedName(forFamily:face:)`）。
    static func displayName(family: String) -> String {
        NSFontManager.shared.localizedName(forFamily: family, face: nil)
    }
}
