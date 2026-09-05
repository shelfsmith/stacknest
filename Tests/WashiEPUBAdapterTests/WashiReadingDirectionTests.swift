// SPDX-License-Identifier: MIT
import Testing
import Foundation
import EPUBAdapter
import EPUBAdapterTestSupport
@testable import WashiEPUBAdapter

@Suite("G48-4: 綴じ方向の解決（宣言 → 実効値）")
struct WashiReadingDirectionTests {
    @Test("宣言があればそれ") func declaredWins() {
        #expect(WashiEPUBReader.direction(declared: "rtl", effective: "ltr") == .rtl)
        #expect(WashiEPUBReader.direction(declared: "LTR", effective: "rtl") == .ltr)
    }
    @Test("default なら実効値") func fallsBackToEffective() {
        #expect(WashiEPUBReader.direction(declared: "default", effective: "rtl") == .rtl)
        #expect(WashiEPUBReader.direction(declared: "", effective: "ltr") == .ltr)
    }
    @Test("どちらも解けなければ unknown") func unknownWhenNeither() {
        #expect(WashiEPUBReader.direction(declared: "default", effective: "") == .unknown)
        #expect(WashiEPUBReader.direction(declared: "x", effective: "y") == .unknown)
    }
    /// 実 EPUB: PPD 未宣言だが本文 CSS が縦書き → Washi が rtl に解決する（1.16.0 の effectiveReadingDirection）。
    @Test("未宣言 PPD＋縦書き CSS の最小 EPUB は rtl で開く") func verticalCSSResolvesToRTL() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g48-4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = try MinimalEPUB.makeVerticalNoPPD(in: dir)
        let info = try await WashiEPUBReader().open(url: url)
        #expect(info.readingDirection == .rtl)
    }
}
