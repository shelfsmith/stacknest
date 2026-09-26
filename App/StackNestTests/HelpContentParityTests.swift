// SPDX-License-Identifier: MIT
import Testing
@testable import StackNest

/// G55: ヘルプの日英は同じ構造を持つ（節の数・各節のブロックの種類と並び・リンク先）。
@Suite("ヘルプの日英の構造（G55）")
struct HelpContentParityTests {
    private func shape(_ s: [HelpSection]) -> [[String]] {
        s.map { $0.blocks.map {
            switch $0 {
            case .para: "para"
            case .bullet: "bullet"
            case .keyRow: "keyRow"
            case .viewerKeyTable: "viewerKeyTable"
            case .link(_, let url): "link:\(url)"
            }
        } }
    }

    @Test("日本語のヘルプは 16 節で、キー表を 1 つ含む")
    func japaneseShape() {
        let ja = HelpContent.ja
        #expect(ja.count == 16)
        #expect(ja.flatMap(\.blocks).filter { $0 == .viewerKeyTable }.count == 1)
    }

    @Test("英語は日本語と同じ構造", .disabled(if: !HelpContent.hasEnglish, "U5 で英語を入れるまで無効"))
    func parity() {
        #expect(shape(HelpContent.en) == shape(HelpContent.ja))
        #expect(HelpContent.en.map(\.title).allSatisfy { !$0.isEmpty })
    }
}
