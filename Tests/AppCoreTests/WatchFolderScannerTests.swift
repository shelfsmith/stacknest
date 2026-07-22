// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("WatchFolderScanner")
struct WatchFolderScannerTests {
    @Test func transientFilesAreExcluded() {
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/a.part")) == true)
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/a.crdownload")) == true)
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/a.download")) == true)
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/a.tmp")) == true)
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/.hidden.zip")) == true)
        #expect(WatchFolderScanner.isTransient(URL(fileURLWithPath: "/x/book.zip")) == false)
    }
    @Test func filtersExistingAndBaseline() {
        let all = ["/d/a.zip", "/d/b.zip", "/d/c.part", "/d/d.zip"].map { URL(fileURLWithPath: $0) }
        let result = WatchFolderScanner.importable(topLevel: all,
            existingLibraryPaths: ["/d/a.zip"], baseline: ["/d/b.zip"])
        #expect(result.map { $0.path } == ["/d/d.zip"])
    }
    @Test func stabilityNeedsTwoEqualObservations() {
        let r1 = WatchFolderScanner.decideStable(previous: [:], current: ["/d/a.zip": 100])
        #expect(r1.stable.isEmpty)
        #expect(r1.pending["/d/a.zip"] == 100)
        let r2 = WatchFolderScanner.decideStable(previous: ["/d/a.zip": 100], current: ["/d/a.zip": 100])
        #expect(r2.stable == ["/d/a.zip"])
        let r3 = WatchFolderScanner.decideStable(previous: ["/d/a.zip": 100], current: ["/d/a.zip": 150])
        #expect(r3.stable.isEmpty)
        #expect(r3.pending["/d/a.zip"] == 150)
    }

    // ---- filterRetry（review follow-up Finding 2） -----------------------------------------
    // 失敗シナリオ: `_notes/`（テキストのみ）のような監視フォルダ直下のディレクトリは
    // フォルダゲートに毎回弾かれるが、サイズが変わらなければ decideStable は永遠に "stable" を
    // 返し続ける（2 回連続同一サイズの定義上）。filterRetry を挟まないと、FolderWatcher は
    // 60 秒ごとに再試行→再失敗→「1 件失敗」バナーを無限に出し続ける。

    @Test func filterRetrySuppressesPathRejectedAtSameSize() {
        let result = WatchFolderScanner.filterRetry(
            stable: ["/watch/_notes"], currentSizes: ["/watch/_notes": 100],
            rejectedSizes: ["/watch/_notes": 100])
        #expect(result.isEmpty,
                "サイズ不変の拒否済み候補が再試行対象に残っている — 毎スキャン失敗＋バナー無限リピートが再発する")
    }

    @Test func filterRetryReattemptsOnceSizeChanges() {
        // 実画像が追加されてディレクトリサイズが増えた想定 → 再試行保証のため必ず対象へ戻る。
        let result = WatchFolderScanner.filterRetry(
            stable: ["/watch/_notes"], currentSizes: ["/watch/_notes": 150],
            rejectedSizes: ["/watch/_notes": 100])
        #expect(result == ["/watch/_notes"], "サイズが変わっても再試行対象から除外されている — 拒否が事実上永続化してしまう")
    }

    @Test func filterRetryPassesThroughNeverRejectedPaths() {
        let result = WatchFolderScanner.filterRetry(
            stable: ["/watch/a.zip"], currentSizes: ["/watch/a.zip": 100], rejectedSizes: [:])
        #expect(result == ["/watch/a.zip"], "拒否履歴の無い通常候補まで誤って抑制してはならない")
    }

    @Test func filterRetryPreservesOrderAndOtherEntries() {
        let result = WatchFolderScanner.filterRetry(
            stable: ["/watch/a.zip", "/watch/_notes", "/watch/b.zip"],
            currentSizes: ["/watch/a.zip": 10, "/watch/_notes": 100, "/watch/b.zip": 20],
            rejectedSizes: ["/watch/_notes": 100])
        #expect(result == ["/watch/a.zip", "/watch/b.zip"])
    }
}
