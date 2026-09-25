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

    // MARK: G54-S3c fix round 1 — リモートの次の巻を差し替える／開き直す／今の本のままにする

    @Test func remoteManifestFailureWithoutLocalFileKeepsTheCurrentBook() {
        // 未ダウンロードで manifest が取れなければ、開き直しても openViewer が同じ manifest で失敗する。
        #expect(SiblingVolumeKind.remoteDecision(localKind: nil, manifestFetched: false,
                                                 filename: "b.epub", manifestFormat: nil) == .failed)
        #expect(SiblingVolumeKind.remoteDecision(localKind: nil, manifestFetched: false,
                                                 filename: "b.zip", manifestFormat: nil) == .failed)
    }

    @Test func remoteManifestFailureWithLocalFileUsesTheLocalCheck() {
        #expect(SiblingVolumeKind.remoteDecision(localKind: .textEPUB, manifestFetched: false,
                                                 filename: "b.epub", manifestFormat: nil) == .swap)
        #expect(SiblingVolumeKind.remoteDecision(localKind: .other, manifestFetched: false,
                                                 filename: "b.epub", manifestFormat: nil) == .reopen)   // 画像本 EPUB
        #expect(SiblingVolumeKind.remoteDecision(localKind: .other, manifestFetched: false,
                                                 filename: "b.zip", manifestFormat: nil) == .reopen)
    }

    @Test func remoteWithLocalFileTrustsTheLocalCheckOverTheManifest() {
        #expect(SiblingVolumeKind.remoteDecision(localKind: .textEPUB, manifestFetched: true,
                                                 filename: "b.epub", manifestFormat: "epub") == .swap)
        #expect(SiblingVolumeKind.remoteDecision(localKind: .other, manifestFetched: true,
                                                 filename: "b.epub", manifestFormat: "epub") == .reopen)
    }

    @Test func remoteManifestFetchedWithoutLocalFileUsesTheManifest() {
        #expect(SiblingVolumeKind.remoteDecision(localKind: nil, manifestFetched: true,
                                                 filename: "b.zip", manifestFormat: "zip") == .reopen)
        #expect(SiblingVolumeKind.remoteDecision(localKind: nil, manifestFetched: true,
                                                 filename: "b.epub", manifestFormat: "text") == .reopen)  // 画像本 EPUB
        #expect(SiblingVolumeKind.remoteDecision(localKind: nil, manifestFetched: true,
                                                 filename: "b.epub", manifestFormat: "epub") == .swap)
    }

    /// G54-S3e（spec §2.1-7）: 取り込み済みでテキスト以外（`.reopen` に決まる）なら manifest は要らない。
    @Test func manifestIsNotNeededForADownloadedNonTextSibling() {
        #expect(SiblingVolumeKind.remoteNeedsManifest(localKind: .other) == false)
        #expect(SiblingVolumeKind.remoteNeedsManifest(localKind: .textEPUB) == true)   // 初期位置に要る
        #expect(SiblingVolumeKind.remoteNeedsManifest(localKind: nil) == true)         // 判定に要る
    }

    /// 取らずに済ませても判定は変わらない（取り込み済みならファイルが正で、manifest の有無に関係なく `.reopen`）。
    @Test func skippingTheManifestDoesNotChangeTheDecision() {
        for fetched in [true, false] {
            for format in ["epub", "archive", nil] as [String?] {
                #expect(SiblingVolumeKind.remoteDecision(localKind: .other, manifestFetched: fetched,
                                                         filename: "b.epub", manifestFormat: format) == .reopen)
            }
        }
    }

    // MARK: G54-S3e — 判定で開いた画像本の handle を使い回す

    /// G54-S3e（spec §2.2）: 判定（`probeLocal`）で開いた画像本の handle があれば、それで content を作る。
    /// 遅延の `EPUBImageBookContent(lazyURL:)` に任せると、同じ本をもう一度開く。
    @Test func contentReusesTheProbedImageBook() async throws {
        let content = try SiblingVolumeKind.content(reusing: FakeImageBook(), orMake: {
            Issue.record("判定で開いた handle があるのに作り直してはいけない")
            throw BookContentError.invalidPath("unused")
        })
        #expect(try await content.pageCount == 1)
    }

    @Test func contentFallsBackToMakeWithoutAHandle() throws {
        var made = 0
        _ = try SiblingVolumeKind.content(reusing: nil, orMake: {
            made += 1
            return EPUBImageBookContent(handle: FakeImageBook())
        })
        #expect(made == 1)
    }
}
