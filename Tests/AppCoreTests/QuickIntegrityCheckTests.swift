// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

@Suite("quick integrity classification (G27a)")
struct QuickIntegrityCheckTests {
    @Test("ファイルが無ければ missing")
    func missingFile() {
        let out = QuickIntegrityCheck.classify(category: .archive, exists: false, probe: nil)
        #expect(out.status == .missing)
        #expect(out.pageCount == nil)
    }

    @Test("動画は対象外")
    func videoIsUnsupported() {
        #expect(QuickIntegrityCheck.classify(category: .video, exists: true, probe: nil).status == .unsupported)
    }

    @Test("テキスト/PDF/EPUB は対象外")
    func textIsUnsupported() {
        #expect(QuickIntegrityCheck.classify(category: .text, exists: true, probe: nil).status == .unsupported)
    }

    @Test("単独画像は開かずに 1 ページと確定できる")
    func singleImageIsOkWithOnePage() {
        let out = QuickIntegrityCheck.classify(category: .image, exists: true, probe: nil)
        #expect(out.status == .ok)
        #expect(out.pageCount == 1)
    }

    @Test("列挙できたアーカイブは ok でページ数が確定する")
    func archiveEnumeratedIsOk() {
        let out = QuickIntegrityCheck.classify(
            category: .archive, exists: true, probe: .enumerated(count: 24, truncated: false))
        #expect(out.status == .ok)
        #expect(out.pageCount == 24)
    }

    @Test("途中打ち切りは damaged で、pages は確定させない")
    func truncatedIsDamagedAndDoesNotSetPages() {
        let out = QuickIntegrityCheck.classify(
            category: .archive, exists: true, probe: .enumerated(count: 13, truncated: true))
        #expect(out.status == .damaged)
        #expect(out.pageCount == nil, "破損時に pages を確定させてはいけない")
    }

    @Test("列挙が失敗したら damaged で理由を保持する")
    func enumerationFailureIsDamaged() {
        let out = QuickIntegrityCheck.classify(
            category: .archive, exists: true, probe: .failed(reason: "open failed"))
        #expect(out.status == .damaged)
        #expect(out.reason == "open failed")
        #expect(out.pageCount == nil)
    }

    @Test("画像 0 枚は empty で pages=0 を確定してよい")
    func zeroImagesIsEmpty() {
        let out = QuickIntegrityCheck.classify(
            category: .archive, exists: true, probe: .enumerated(count: 0, truncated: false))
        #expect(out.status == .empty)
        #expect(out.pageCount == 0, "毎回再走査しないよう 0 は確定させる")
    }

    @Test("フォルダはアーカイブと同じく列挙結果で判定する")
    func folderIsProbedLikeArchive() {
        let out = QuickIntegrityCheck.classify(
            category: .folder, exists: true, probe: .enumerated(count: 7, truncated: false))
        #expect(out.status == .ok)
        #expect(out.pageCount == 7)
    }

    @Test("列挙が要るのは archive と folder だけ")
    func needsProbeOnlyForArchiveAndFolder() {
        #expect(QuickIntegrityCheck.needsProbe(category: .archive))
        #expect(QuickIntegrityCheck.needsProbe(category: .folder))
        #expect(QuickIntegrityCheck.needsProbe(category: .image) == false)
        #expect(QuickIntegrityCheck.needsProbe(category: .video) == false)
        #expect(QuickIntegrityCheck.needsProbe(category: .text) == false)
    }

    @Test("列挙が必要なのに渡されなければ理由付きの damaged（呼び出し側のバグを隠さない）")
    func missingProbeForArchiveIsDamagedWithReason() {
        let out = QuickIntegrityCheck.classify(category: .archive, exists: true, probe: nil)
        #expect(out.status == .damaged)
        #expect(out.reason == "probe not performed")
    }
}
