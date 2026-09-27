// SPDX-License-Identifier: MIT
import Testing
@testable import WashiEPUBAdapter

@Suite("G56-S2: 文の位置の符号化（cfi 枠）")
struct WashiTextAnchorCodecTests {
    @Test func roundTripsOffsetAndIdref() {
        let s = WashiTextAnchorCodec.encode(textOffset: 1234, idref: "ch04")
        #expect(s == "washi:t=1234;idref=ch04")
        let d = WashiTextAnchorCodec.decode(s)
        #expect(d?.textOffset == 1234)
        #expect(d?.idref == "ch04")
    }
    @Test func percentEncodesSeparatorsInIdref() {
        let s = WashiTextAnchorCodec.encode(textOffset: 0, idref: "a;b=c%d")
        #expect(!s.dropFirst("washi:".count).contains("a;b"))
        #expect(WashiTextAnchorCodec.decode(s)?.idref == "a;b=c%d")
    }
    @Test func idrefMayBeAbsent() {
        let s = WashiTextAnchorCodec.encode(textOffset: 7, idref: nil)
        #expect(s == "washi:t=7")
        #expect(WashiTextAnchorCodec.decode(s)?.idref == nil)
        #expect(WashiTextAnchorCodec.decode(s)?.textOffset == 7)
    }
    @Test(arguments: [nil, "", "epubcfi(/6/4)", "washi:", "washi:t=", "washi:t=-1", "washi:t=abc",
                      "washi:idref=ch1", "washi:t=99999999999999999999999"])
    func brokenOrForeignIsNil(_ input: String?) {
        #expect(WashiTextAnchorCodec.decode(input) == nil)
    }
    @Test func unknownKeysAreIgnored() {
        let d = WashiTextAnchorCodec.decode("washi:t=5;future=x;idref=c2")
        #expect(d?.textOffset == 5)
        #expect(d?.idref == "c2")
    }
}
