// SPDX-License-Identifier: MIT
import Testing
import EPUBAdapter
import EPUBAdapterTestSupport
@testable import WashiEPUBAdapter

@Suite("Washi 実装")
struct WashiEPUBReaderTests {
    @Test("契約テストを通る")
    func contract() async throws {
        try await EPUBReadingContract.run(WashiEPUBReader())
    }

    @Test("綴じ方向は rawValue で写す")
    func direction() {
        #expect(WashiEPUBReader.direction(rawValue: "rtl") == .rtl)
        #expect(WashiEPUBReader.direction(rawValue: "LTR") == .ltr)
        #expect(WashiEPUBReader.direction(rawValue: "default") == .unknown)
    }
}
