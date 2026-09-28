// SPDX-License-Identifier: MIT
import Testing
@testable import StackNest

@Suite("G56-S3: EPUB の書体の候補")
struct EPUBFontCandidatesTests {
    @Test func onlyInstalledInPreferredOrder() {
        let installed: Set<String> = ["YuGothic", "Hiragino Mincho ProN", "Comic Sans MS", "Klee"]
        let list = EPUBFontCandidates.available(installed: installed, localizedName: { "L(\($0))" })
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
        #expect(EPUBFontCandidates.availableOnThisMac().contains { $0.family == "Hiragino Sans" })
    }
}
