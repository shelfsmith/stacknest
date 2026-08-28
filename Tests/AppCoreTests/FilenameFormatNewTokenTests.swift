// SPDX-License-Identifier: MIT
import Testing
import Foundation
import StackroomFormat
@testable import AppCore

@Suite("追加トークン @series / @volume / @keywordC")
struct FilenameFormatNewTokenTests {
    private func record(series: String? = nil, volume: Double? = nil,
                        keywordC: String? = nil, title: String = "T") -> BookRecord {
        BookRecord(id: 1, title: title, dateAdded: Date(),
                   keywordC: keywordC, series: series, volume: volume)
    }

    @Test("@series と @keywordC はそのまま出る")
    func plainTokens() throws {
        let f = try FilenameFormat(raw: "@series @keywordC")
        let s = FilenameFormatter.format(record(series: "がっこう", keywordC: "K"), with: f)
        #expect(s == "がっこう K")
    }

    @Test("@volume は桁を埋める")
    func volumePadding() throws {
        let f = try FilenameFormat(raw: "v@volume")
        #expect(FilenameFormatter.format(record(volume: 7), with: f, volumeWidth: 2) == "v07")
        #expect(FilenameFormatter.format(record(volume: 7), with: f, volumeWidth: 3) == "v007")
        #expect(FilenameFormatter.format(record(volume: 120), with: f, volumeWidth: 3) == "v120")
    }

    @Test("小数は整数部だけ埋める")
    func fractionalVolume() throws {
        let f = try FilenameFormat(raw: "v@volume")
        #expect(FilenameFormatter.format(record(volume: 7.5), with: f, volumeWidth: 2) == "v07.5")
        #expect(FilenameFormatter.format(record(volume: 7.0), with: f, volumeWidth: 2) == "v07")
    }

    @Test("巻数が無い本ではトークンが落ちる")
    func absentVolume() throws {
        let f = try FilenameFormat(raw: "@title[ v@volume]")
        #expect(FilenameFormatter.format(record(volume: nil, title: "T"), with: f) == "T")
    }

    @Test("既存の書式の解釈は変わらない")
    func existingFormatUnchanged() throws {
        let f = try FilenameFormat(raw: "[@author] @title")
        let r = BookRecord(id: 1, title: "本", author: "著", dateAdded: Date())
        #expect(FilenameFormatter.format(r, with: f) == "[著] 本")
    }

    @Test("★ 括弧の中の @volume にも桁が届く")
    func volumeInsideBracketGroup() throws {
        let f = try FilenameFormat(raw: "@title[ v@volume]")
        let result = FilenameFormatter.format(record(volume: 7, title: "T"), with: f, volumeWidth: 3)
        #expect(result == "T[ v007]")
    }

    @Test("大きな巻数が切り詰められない")
    func largeVolume() throws {
        let f = try FilenameFormat(raw: "v@volume")
        #expect(FilenameFormatter.format(record(volume: 10_000_000_000), with: f, volumeWidth: 2) == "v10000000000")
    }

    @Test("整数のすぐ下の値でも桁が混ざらない")
    func nearIntegerVolume() throws {
        let f = try FilenameFormat(raw: "v@volume")
        #expect(FilenameFormatter.format(record(volume: 6.999999999999), with: f, volumeWidth: 2) == "v07")
    }
}
