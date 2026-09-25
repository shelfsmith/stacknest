// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G54-S3e（spec §2.6）: EXIF の向きの情報（Orientation）付きの画像が、縮小・変換を通っても正しい向きになること。
/// 本体は 4.2e `339fd106` で修正済み（`kCGImageSourceCreateThumbnailWithTransform: true`）。ここは確認と端の修正。
@Suite("G54-S3e: EXIF の回転")
struct EXIFOrientationTests {
    /// 端の修正: 縮小不要（元幅 ≤ maxWidth）のとき元のバイト列を返していた。判断は回転前の幅で、向きの情報も残っていた。
    @Test func transcoderBakesTheRotationEvenWhenNoDownscaleIsNeeded() throws {
        let data = OrientedJPEGFixture.make(width: 400, height: 200, orientation: 6)
        let out = ImageIOTranscoder().scaled(data, maxWidth: 800)
        let i = try #require(OrientedJPEGFixture.info(out))
        #expect(i.orientation == 1)
        #expect(i.width == 200)
        #expect(i.height == 400)
    }

    /// 最終レビュー Minor: 縮小要否の判定は「表示上の幅」で行う。元幅（回転前）だけで比べると、
    /// 縦長の元画像（orientation 5–8 で表示は横長になる）が縮め忘れになる。
    /// 1000×2000・orientation 6（表示は 2000×1000）を maxWidth=1600 で縮めると、表示幅は 1600 以下になるはず。
    @Test func transcoderDownscalesByDisplayedWidthNotRawWidth() throws {
        let data = OrientedJPEGFixture.make(width: 1000, height: 2000, orientation: 6)
        let out = ImageIOTranscoder().scaled(data, maxWidth: 1600)
        let i = try #require(OrientedJPEGFixture.info(out))
        #expect(i.orientation == 1)
        // 回転を焼き込んだ後は width がそのまま表示上の幅。
        #expect(i.width <= 1600)
    }

    @Test func transcoderStillReturnsUprightSmallImagesByteForByte() {
        let data = OrientedJPEGFixture.make(width: 400, height: 200, orientation: 1)
        #expect(ImageIOTranscoder().scaled(data, maxWidth: 800) == data)
    }

    @Test func transcoderBakesTheRotationWhenDownscaling() throws {
        let data = OrientedJPEGFixture.make(width: 2000, height: 1000, orientation: 6)
        let out = ImageIOTranscoder().scaled(data, maxWidth: 500)
        let i = try #require(OrientedJPEGFixture.info(out))
        #expect(i.orientation == 1)
        #expect(i.height > i.width)
        #expect(max(i.width, i.height) <= 500)
    }

    /// 表紙の縮小は向きの情報を残す作りでも焼き込む作りでもよい。**見た目の向き**が回転後であることを確かめる
    /// （向きの情報が残る場合は、読む側の `ThumbnailLoader` がそれを当てる — `ThumbnailLoaderTests` 参照）。
    @Test func coverResizerKeepsTheDisplayedOrientation() throws {
        let data = OrientedJPEGFixture.make(width: 2000, height: 1000, orientation: 6)
        let out = CoverImageResizer.resizeJPEG(data, maxPixelSize: 500)
        let shown = try #require(OrientedJPEGFixture.displayedSize(out))
        #expect(shown.height > shown.width)
        #expect(max(shown.width, shown.height) <= 500)
    }

    @Test func coverResizerPassThroughKeepsTheMark() throws {
        let data = OrientedJPEGFixture.make(width: 400, height: 200, orientation: 6)
        let out = CoverImageResizer.resizeJPEG(data, maxPixelSize: 800)
        let shown = try #require(OrientedJPEGFixture.displayedSize(out))
        #expect(shown.width == 200)
        #expect(shown.height == 400)
    }
}
