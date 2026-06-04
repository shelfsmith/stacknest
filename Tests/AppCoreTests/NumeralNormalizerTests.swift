// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("NumeralNormalizer")
struct NumeralNormalizerTests {
    @Test func arabicHalfWidth() {
        #expect(NumeralNormalizer.toDouble("0") == 0.0)
        #expect(NumeralNormalizer.toDouble("5") == 5.0)
        #expect(NumeralNormalizer.toDouble("5.5") == 5.5)
        #expect(NumeralNormalizer.toDouble("12") == 12.0)
    }
    @Test func arabicFullWidth() {
        #expect(NumeralNormalizer.toDouble("０") == 0.0)
        #expect(NumeralNormalizer.toDouble("５") == 5.0)
        #expect(NumeralNormalizer.toDouble("５．５") == 5.5)
    }
    @Test func kanjiZero() {
        #expect(NumeralNormalizer.toDouble("〇") == 0.0)
        #expect(NumeralNormalizer.toDouble("零") == 0.0)
    }
    @Test func kanjiBasic() {
        for (input, expected) in [("一", 1.0), ("二", 2.0), ("三", 3.0), ("四", 4.0),
                                   ("五", 5.0), ("六", 6.0), ("七", 7.0), ("八", 8.0),
                                   ("九", 9.0), ("十", 10.0)] {
            #expect(NumeralNormalizer.toDouble(input) == expected)
        }
    }
    @Test func kanjiCompound() {
        #expect(NumeralNormalizer.toDouble("十一") == 11.0)
        #expect(NumeralNormalizer.toDouble("十二") == 12.0)
        #expect(NumeralNormalizer.toDouble("二十") == 20.0)
        #expect(NumeralNormalizer.toDouble("二十一") == 21.0)
        #expect(NumeralNormalizer.toDouble("百") == 100.0)
        #expect(NumeralNormalizer.toDouble("千") == 1000.0)
    }
    @Test func kanjiKyuujitai() {
        for (input, expected) in [("壱", 1.0), ("弐", 2.0), ("参", 3.0), ("肆", 4.0),
                                   ("伍", 5.0), ("陸", 6.0), ("柒", 7.0), ("捌", 8.0),
                                   ("玖", 9.0), ("拾", 10.0)] {
            #expect(NumeralNormalizer.toDouble(input) == expected)
        }
    }
    @Test func romanUnicode() {
        for (input, expected) in [("Ⅰ", 1.0), ("Ⅱ", 2.0), ("Ⅲ", 3.0), ("Ⅳ", 4.0),
                                   ("Ⅴ", 5.0), ("Ⅹ", 10.0), ("Ⅻ", 12.0)] {
            #expect(NumeralNormalizer.toDouble(input) == expected)
        }
    }
    @Test func romanASCII() {
        for (input, expected) in [("I", 1.0), ("II", 2.0), ("III", 3.0), ("IV", 4.0),
                                   ("V", 5.0), ("IX", 9.0), ("X", 10.0), ("XII", 12.0)] {
            #expect(NumeralNormalizer.toDouble(input) == expected)
        }
    }
    @Test func greek() {
        for (input, expected) in [("α", 1.0), ("β", 2.0), ("γ", 3.0), ("ω", 24.0)] {
            #expect(NumeralNormalizer.toDouble(input) == expected)
        }
    }
    @Test func unparseable() {
        #expect(NumeralNormalizer.toDouble("xyz") == nil)
        #expect(NumeralNormalizer.toDouble("") == nil)
    }
}
