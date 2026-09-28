// SPDX-License-Identifier: MIT
import Testing
@testable import StackNest

@Suite("G56-S3/G57: EPUB の書体の候補")
struct EPUBFontCandidatesTests {
    @Test func onlyInstalledInPreferredOrder() {
        let installed: Set<String> = ["YuGothic", "Hiragino Mincho ProN", "Comic Sans MS", "Klee"]
        let list = EPUBFontCandidates.available(EPUBFontCandidates.preferredJapaneseFamilies,
                                                installed: installed, localizedName: { "L(\($0))" })
        #expect(list.map(\.family) == ["Hiragino Mincho ProN", "YuGothic", "Klee"])
        #expect(list.first?.displayName == "L(Hiragino Mincho ProN)")
    }

    @Test func effectiveFamilyFallsBackWhenMissing() {
        let installed: Set<String> = ["YuMincho"]
        #expect(EPUBFontCandidates.effectiveFamily("YuMincho", installed: installed) == "YuMincho")
        #expect(EPUBFontCandidates.effectiveFamily("Toppan Bunkyu Mincho", installed: installed) == nil)
        #expect(EPUBFontCandidates.effectiveFamily(nil, installed: installed) == nil)
    }

    @Test func thisMacHasAtLeastHiragino() {
        #expect(EPUBFontCandidates.availableOnThisMac(EPUBFontCandidates.preferredJapaneseFamilies)
            .contains { $0.family == "Hiragino Sans" })
    }

    // G57 Task 4
    @Test func latinCandidatesOnlyInstalled() {
        let list = EPUBFontCandidates.available(EPUBFontCandidates.preferredLatinFamilies,
                                                installed: ["Georgia", "Comic Sans MS", "Baskerville"], localizedName: { $0 })
        #expect(list.map(\.family) == ["Baskerville", "Georgia"])
    }

    @Test func detectsJapaneseGlyphs() {
        #expect(EPUBFontCandidates.hasJapaneseGlyphs(family: "Hiragino Sans"))
        #expect(!EPUBFontCandidates.hasJapaneseGlyphs(family: "Georgia"))
        #expect(!EPUBFontCandidates.hasJapaneseGlyphs(family: "No Such Font 12345"))
    }
}
