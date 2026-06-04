// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("FilenameParser")
struct FilenameParserTests {
    @Test func extractsDaiNKan() {
        let r = FilenameParser.parse(title: "ワンピース 第5巻", filename: nil)
        #expect(r.series == "ワンピース")
        #expect(r.volume == 5.0)
    }
    @Test func extractsVolN() {
        let r = FilenameParser.parse(title: "Naruto Vol.7", filename: nil)
        #expect(r.series == "Naruto")
        #expect(r.volume == 7.0)
    }
    @Test func extractsVolumeN() {
        let r = FilenameParser.parse(title: "Akira Volume 3", filename: nil)
        #expect(r.series == "Akira")
        #expect(r.volume == 3.0)
    }
    @Test func extractsTrailingParen() {
        let r = FilenameParser.parse(title: "ベルセルク (12)", filename: nil)
        #expect(r.series == "ベルセルク")
        #expect(r.volume == 12.0)
    }
    @Test func extractsTrailingSpaceN() {
        let r = FilenameParser.parse(title: "デスノート 8", filename: nil)
        #expect(r.series == "デスノート")
        #expect(r.volume == 8.0)
    }
    @Test func extractsKanjiVolume() {
        let r = FilenameParser.parse(title: "鬼滅の刃 第三巻", filename: nil)
        #expect(r.series == "鬼滅の刃")
        #expect(r.volume == 3.0)
    }
    @Test func extractsRomanVolume() {
        let r = FilenameParser.parse(title: "Final Fantasy Vol.Ⅴ", filename: nil)
        #expect(r.volume == 5.0)
    }
    @Test func extractsZeroVolume() {
        let r = FilenameParser.parse(title: "進撃の巨人 第0巻", filename: nil)
        #expect(r.series == "進撃の巨人")
        #expect(r.volume == 0.0)
    }
    @Test func extractsKanjiZeroVolume() {
        let r = FilenameParser.parse(title: "鬼滅の刃 第零巻", filename: nil)
        #expect(r.volume == 0.0)
    }
    @Test func upperLowerTwoVolume() {
        let r1 = FilenameParser.parse(title: "アキラ 上巻", filename: nil)
        #expect(r1.volume == 1.0)
        let r2 = FilenameParser.parse(title: "アキラ 下巻", filename: nil)
        #expect(r2.volume == 2.0)
    }
    @Test func upperMiddleLowerThreeVolume() {
        // 同 title 内に「中巻」マーカーがあれば 3 巻構成と判定
        let r = FilenameParser.parse(title: "アキラ 中巻", filename: nil)
        #expect(r.volume == 2.0)
    }
    @Test func fallbackToFilename() {
        let r = FilenameParser.parse(title: "短いタイトル", filename: "ワンピース 第5巻.zip")
        #expect(r.volume == 5.0)
    }
    @Test func noVolumeNoSeries() {
        let r = FilenameParser.parse(title: "短いタイトル", filename: nil)
        #expect(r.volume == nil)
        #expect(r.series == nil)
    }
}
