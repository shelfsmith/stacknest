// SPDX-License-Identifier: MIT
import Testing
import Foundation
import EPUBAdapter
@testable import AppCore

/// G54-S3c: 巻送りの次の巻を、どのビューアで読むか。テキスト EPUB は EPUB の窓、それ以外は画像ビューア。
@Suite("G54-S3c: 次の巻をどのビューアで読むか")
struct SiblingVolumeKindTests {
    final class FakeImageBook: EPUBImageBookReading, Sendable {
        let pageCount = 1
        let readingDirection: EPUBReadingDirection = .ltr
        let spreads: [EPUBPageSpread] = [.none]
        func imageData(at index: Int) async throws -> Data { Data() }
    }

    struct StubReader: EPUBReading {
        enum Mode: Sendable { case imageBook, textBook, fails, mustNotBeCalled }
        let mode: Mode
        func open(url: URL) async throws -> EPUBBookInfo { throw EPUBAdapterError.cannotOpen("unused") }
        func coverImageData(url: URL, maxPixelSize: Int) async throws -> Data? { nil }
        func openImageBook(url: URL) async throws -> (any EPUBImageBookReading)? {
            switch mode {
            case .imageBook: return FakeImageBook()
            case .textBook: return nil
            case .fails: throw EPUBAdapterError.cannotOpen("broken")
            case .mustNotBeCalled:
                Issue.record("EPUB でないファイルで openImageBook を呼んではいけない")
                return nil
            }
        }
    }

    @Test func localNonEPUBIsOther() {
        #expect(SiblingVolumeKind.local(path: "/a/b.zip", isImageBook: nil) == .other)
        #expect(SiblingVolumeKind.local(path: "/a/folder", isImageBook: nil) == .other)
        #expect(SiblingVolumeKind.local(path: nil, isImageBook: nil) == .other)
    }

    @Test func localEPUBDependsOnTheImageBookCheck() {
        #expect(SiblingVolumeKind.local(path: "/a/b.EPUB", isImageBook: false) == .textEPUB)
        #expect(SiblingVolumeKind.local(path: "/a/b.epub", isImageBook: true) == .other)
    }

    /// 確かめられなかった .epub はテキスト扱い（本を開く経路が判定失敗で EPUB の窓へ落とすのと同じ）。
    @Test func localEPUBThatCouldNotBeCheckedIsTextEPUB() {
        #expect(SiblingVolumeKind.local(path: "/a/b.epub", isImageBook: nil) == .textEPUB)
    }

    @Test func remoteFollowsTheManifest() {
        #expect(SiblingVolumeKind.remote(filename: "b.epub", manifestFormat: "epub") == .textEPUB)
        #expect(SiblingVolumeKind.remote(filename: "b.epub", manifestFormat: "text") == .other)   // 画像本 EPUB
        #expect(SiblingVolumeKind.remote(filename: "b.zip", manifestFormat: "epub") == .other)    // 拡張子が違えば信じない
        #expect(SiblingVolumeKind.remote(filename: "b.epub", manifestFormat: nil) == .other)      // manifest が取れない
    }

    @Test func probeLocalReturnsTheHandleForAnImageBook() async {
        let r = await SiblingVolumeKind.probeLocal(path: "/a/b.epub", reader: StubReader(mode: .imageBook))
        #expect(r.kind == .other)
        #expect(r.imageBook?.pageCount == 1)
    }

    @Test func probeLocalDetectsATextEPUB() async {
        let r = await SiblingVolumeKind.probeLocal(path: "/a/b.epub", reader: StubReader(mode: .textBook))
        #expect(r.kind == .textEPUB)
        #expect(r.imageBook == nil)
    }

    @Test func probeLocalTreatsAFailedCheckOrNoReaderAsText() async {
        let failed = await SiblingVolumeKind.probeLocal(path: "/a/b.epub", reader: StubReader(mode: .fails))
        #expect(failed.kind == .textEPUB)
        let noReader = await SiblingVolumeKind.probeLocal(path: "/a/b.epub", reader: nil)
        #expect(noReader.kind == .textEPUB)
    }

    @Test func probeLocalDoesNotOpenNonEPUBFiles() async {
        let r = await SiblingVolumeKind.probeLocal(path: "/a/b.cbz", reader: StubReader(mode: .mustNotBeCalled))
        #expect(r.kind == .other)
    }
}
