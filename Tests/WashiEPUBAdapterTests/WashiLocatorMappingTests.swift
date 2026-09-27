// SPDX-License-Identifier: MIT
import Testing
import WashiCore
import EPUBAdapter
@testable import WashiEPUBAdapter

@Suite("Washi の位置と契約の位置の写像")
struct WashiLocatorMappingTests {
    @Test("Washi → 契約: アンカーが無ければ cfi は nil（従来どおり）")
    func toValueWithoutAnchor() {
        let v = WashiLocatorMapping.toValue(EPUBLocator(spineIndex: 4, progression: 0.5, idref: "ch4"))
        #expect(v == EPUBLocatorValue(spine: 4, progress: 0.5, cfi: nil, engine: "washi"))
    }
    @Test("Washi → 契約: アンカーは cfi に符号化する（idref も）")
    func toValueWithAnchor() {
        let v = WashiLocatorMapping.toValue(EPUBLocator(spineIndex: 4, progression: 0.5, idref: "ch4", textOffset: 321))
        #expect(v == EPUBLocatorValue(spine: 4, progress: 0.5, cfi: "washi:t=321;idref=ch4", engine: "washi"))
    }
    @Test("契約 → Washi: washi の cfi からアンカーと idref を戻す（idref が無いと Washi がアンカーを捨てる）")
    func toWashiRestoresAnchor() {
        let l = WashiLocatorMapping.toWashi(EPUBLocatorValue(spine: 4, progress: 0.5, cfi: "washi:t=321;idref=ch4", engine: "washi"))
        #expect(l.spineIndex == 4 && l.progression == 0.5)
        #expect(l.textOffset == 321)
        #expect(l.idref == "ch4")
    }
    @Test("契約 → Washi: 他エンジンの cfi・壊れた cfi・旧データは spine＋progress だけ")
    func toWashiIgnoresForeignOrBroken() {
        for v in [EPUBLocatorValue(spine: 2, progress: 0.75, cfi: "epubcfi(/6/4)", engine: "foliate"),
                  EPUBLocatorValue(spine: 2, progress: 0.75, cfi: "washi:t=x", engine: "washi"),
                  EPUBLocatorValue(spine: 2, progress: 0.75, cfi: nil, engine: "washi"),
                  EPUBLocatorValue(spine: 2, progress: 0.75, cfi: nil, engine: nil)] {
            let l = WashiLocatorMapping.toWashi(v)
            #expect(l.spineIndex == 2 && l.progression == 0.75)
            #expect(l.textOffset == nil && l.idref == nil)
        }
    }
    @Test("Washi の PageSpreadSlot を契約の EPUBPageSpread へ rawValue で写す")
    func spreadMapping() {
        #expect(WashiEPUBReader.spread(from: .left) == .left)
        #expect(WashiEPUBReader.spread(from: .right) == .right)
        #expect(WashiEPUBReader.spread(from: .center) == .center)
        #expect(WashiEPUBReader.spread(from: nil) == .none)
    }
}
