// SPDX-License-Identifier: MIT
import Testing
import WashiCore
import EPUBAdapter
@testable import WashiEPUBAdapter

@Suite("Washi の位置と契約の位置の写像")
struct WashiLocatorMappingTests {
    @Test("Washi → 契約: spine と progress を写し engine は washi")
    func toValue() {
        let v = WashiLocatorMapping.toValue(EPUBLocator(spineIndex: 4, progression: 0.5, idref: "ch4"))
        #expect(v == EPUBLocatorValue(spine: 4, progress: 0.5, cfi: nil, engine: "washi"))
    }
    @Test("契約 → Washi: 他エンジンの cfi は無視して spine＋progress で復元")
    func toWashi() {
        let l = WashiLocatorMapping.toWashi(EPUBLocatorValue(spine: 2, progress: 0.75, cfi: "epubcfi(/6/4)", engine: "foliate"))
        #expect(l.spineIndex == 2 && l.progression == 0.75 && l.idref == nil)
    }
}
