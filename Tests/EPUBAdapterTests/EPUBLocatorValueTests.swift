// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import EPUBAdapter

@Suite("EPUB の読書位置の値型")
struct EPUBLocatorValueTests {
    @Test("Codable 往復（cfi と engine が nil でも）")
    func codableRoundTrip() throws {
        let a = EPUBLocatorValue(spine: 3, progress: 0.25, cfi: "epubcfi(/6/8!/4/2)", engine: "foliate")
        let b = EPUBLocatorValue(spine: 0, progress: 0, cfi: nil, engine: nil)
        for v in [a, b] {
            let data = try JSONEncoder().encode(v)
            #expect(try JSONDecoder().decode(EPUBLocatorValue.self, from: data) == v)
        }
    }

    @Test("progress は 0…1 に丸める")
    func clamps() {
        #expect(EPUBLocatorValue(spine: 1, progress: 1.7, cfi: nil, engine: nil).progress == 1)
        #expect(EPUBLocatorValue(spine: 1, progress: -0.2, cfi: nil, engine: nil).progress == 0)
    }

    @Test("★ engine が違えば cfi を捨てる（共有の正は spine＋progress）")
    func dropsForeignCFI() {
        let v = EPUBLocatorValue(spine: 3, progress: 0.25, cfi: "epubcfi(/6/8!/4/2)", engine: "foliate")
        let forWashi = v.restorable(for: "washi")
        #expect(forWashi.cfi == nil)
        #expect(forWashi.spine == 3 && forWashi.progress == 0.25)
        #expect(v.restorable(for: "foliate").cfi == "epubcfi(/6/8!/4/2)")
    }

    @Test("旧形式（spine と progress だけ）の JSON も読める")
    func decodesMinimalJSON() throws {
        let json = Data(#"{"spine":2,"progress":0.5}"#.utf8)
        let v = try JSONDecoder().decode(EPUBLocatorValue.self, from: json)
        #expect(v == EPUBLocatorValue(spine: 2, progress: 0.5, cfi: nil, engine: nil))
    }
}
