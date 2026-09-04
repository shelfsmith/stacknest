// SPDX-License-Identifier: MIT
import Testing
@testable import EPUBAdapter

@Suite("画像本の判定")
struct EPUBImageBookDetectionTests {
    @Test("全項目に画像パスがあれば画像本")
    func allImages() {
        #expect(EPUBImageBookDetection.isImageBook(simpleImagePaths: ["a.jpg", "b.jpg", "c.png"]) == true)
    }
    @Test("1 つでも欠ければ画像本ではない（テキストページを画像ビューアでは出せない）")
    func oneText() {
        #expect(EPUBImageBookDetection.isImageBook(simpleImagePaths: ["a.jpg", nil, "c.png"]) == false)
    }
    @Test("空なら画像本ではない")
    func empty() {
        #expect(EPUBImageBookDetection.isImageBook(simpleImagePaths: []) == false)
    }
}
