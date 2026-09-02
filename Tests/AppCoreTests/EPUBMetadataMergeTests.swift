// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("EPUB メタデータの合流")
struct EPUBMetadataMergeTests {
    @Test("既存があれば既存のまま（上書きしない）")
    func keepsExisting() {
        #expect(EPUBMetadataMerge.merged(existing: "手で直した", fromEPUB: "EPUB の値") == "手で直した")
    }
    @Test("既存が nil / 空白なら EPUB の値")
    func fillsWhenEmpty() {
        #expect(EPUBMetadataMerge.merged(existing: nil, fromEPUB: "EPUB の値") == "EPUB の値")
        #expect(EPUBMetadataMerge.merged(existing: "   ", fromEPUB: "EPUB の値") == "EPUB の値")
    }
    @Test("両方 nil なら nil。EPUB 側が空白だけなら採らない")
    func bothEmpty() {
        #expect(EPUBMetadataMerge.merged(existing: nil, fromEPUB: nil) == nil)
        #expect(EPUBMetadataMerge.merged(existing: nil, fromEPUB: " ") == nil)
    }
}
