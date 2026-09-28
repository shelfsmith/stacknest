// SPDX-License-Identifier: MIT
import AppKit

/// G56-S3: EPUB の書体の候補 1 つ。`family` は保存値と Washi へ渡す CSS のファミリー名。
struct EPUBFontCandidate: Identifiable, Equatable {
    let family: String
    let displayName: String
    var id: String { family }
}

/// G56-S3: macOS に標準で入る（またはダウンロードで入る）和文書体から、機械にあるものだけを候補にする。
enum EPUBFontCandidates {
    /// 表示順。2026-09-28 に母艦（macOS 26.6.2）で実在を確認したファミリー名。
    static let preferredFamilies = [
        "Hiragino Mincho ProN", "Hiragino Sans", "Hiragino Maru Gothic ProN",
        "YuMincho", "YuGothic",
        "Toppan Bunkyu Mincho", "Toppan Bunkyu Gothic",
        "Tsukushi A Round Gothic", "Klee", "YuKyokasho",
        "BIZ UDMincho", "BIZ UDGothic",
    ]

    static func available(installed: Set<String>, localizedName: (String) -> String) -> [EPUBFontCandidate] {
        preferredFamilies.filter(installed.contains).map { EPUBFontCandidate(family: $0, displayName: localizedName($0)) }
    }

    static func availableOnThisMac() -> [EPUBFontCandidate] {
        let fm = NSFontManager.shared
        return available(installed: Set(fm.availableFontFamilies),
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
}
