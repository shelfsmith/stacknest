// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("巻数の桁")
struct VolumeWidthTests {
    @Test("最大巻が 1 桁でも最低 2 桁")
    func minimumTwo() {
        #expect(VolumeWidth.width(forMax: 9) == 2)
        #expect(VolumeWidth.width(forMax: 1) == 2)
    }

    @Test("最大巻が 3 桁なら 3 桁")
    func threeDigits() {
        #expect(VolumeWidth.width(forMax: 120) == 3)
        #expect(VolumeWidth.width(forMax: 100) == 3)
        #expect(VolumeWidth.width(forMax: 99) == 2)
    }

    @Test("最大巻が無い / 0 以下なら 2 桁")
    func absent() {
        #expect(VolumeWidth.width(forMax: nil) == 2)
        #expect(VolumeWidth.width(forMax: 0) == 2)
    }

    @Test("小数を持つ最大巻は整数部で数える")
    func fractional() {
        #expect(VolumeWidth.width(forMax: 99.5) == 2)
        #expect(VolumeWidth.width(forMax: 100.5) == 3)
    }

    @Test("鍵は NFC 正規化される")
    func nfcKeys() {
        // "が" の分解形（U+304B U+3099）で入れても、合成形で引ける
        let decomposed = "\u{304B}\u{3099}っこう"
        let widths = VolumeWidth.widths(fromMaxVolumes: [decomposed: 120])
        #expect(widths["がっこう"] == 3)
    }
}
