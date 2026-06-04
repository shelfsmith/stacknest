// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("SpreadPaginator")
struct SpreadPaginatorTests {
    // ヘルパ: 全縦長・オーバーライド無し
    private func allPortrait(_ p: Int) -> Bool { false }
    private func noOverride(_ p: Int) -> PageLayoutOverride? { nil }

    @Test func emptyBookReturnsEmpty() {
        let s = SpreadPaginator.paginate(pageCount: 0, isLandscape: allPortrait, override: noOverride, coverOffset: true)
        #expect(s == [])
    }

    @Test func singlePage() {
        let s = SpreadPaginator.paginate(pageCount: 1, isLandscape: allPortrait, override: noOverride, coverOffset: true)
        #expect(s == [Spread(pages: [0])])
    }

    @Test func sevenPortraitWithCoverOffset() {
        // 表紙独立: [0] 単独, 以降ペア → [0],[1,2],[3,4],[5,6]
        let s = SpreadPaginator.paginate(pageCount: 7, isLandscape: allPortrait, override: noOverride, coverOffset: true)
        #expect(s == [
            Spread(pages: [0]),
            Spread(pages: [1, 2]),
            Spread(pages: [3, 4]),
            Spread(pages: [5, 6]),
        ])
    }

    @Test func sevenPortraitWithoutCoverOffset() {
        // 先頭からペア → [0,1],[2,3],[4,5],[6]（最後は奇数余りで単独）
        let s = SpreadPaginator.paginate(pageCount: 7, isLandscape: allPortrait, override: noOverride, coverOffset: false)
        #expect(s == [
            Spread(pages: [0, 1]),
            Spread(pages: [2, 3]),
            Spread(pages: [4, 5]),
            Spread(pages: [6]),
        ])
    }

    @Test func oddRemainderIsSolo() {
        // 3 ページ・表紙オフセット無し → [0,1],[2]
        let s = SpreadPaginator.paginate(pageCount: 3, isLandscape: allPortrait, override: noOverride, coverOffset: false)
        #expect(s == [Spread(pages: [0, 1]), Spread(pages: [2])])
    }

    @Test func landscapeMidBookAutoSoloAndRepair() {
        // 6 ページ・page 2 のみ横長・表紙オフセット無し
        // [0,1], [2](横長単独), [3,4], [5]
        let landscape: (Int) -> Bool = { $0 == 2 }
        let s = SpreadPaginator.paginate(pageCount: 6, isLandscape: landscape, override: noOverride, coverOffset: false)
        #expect(s == [
            Spread(pages: [0, 1]),
            Spread(pages: [2]),
            Spread(pages: [3, 4]),
            Spread(pages: [5]),
        ])
    }

    @Test func forceSoloOnPortraitPage() {
        // 4 ページ全縦長・page 1 を forceSolo・表紙オフセット無し
        // [0](page1 が solo なのでペア不成立), [1](forceSolo), [2,3]
        let override: (Int) -> PageLayoutOverride? = { $0 == 1 ? .forceSolo : nil }
        let s = SpreadPaginator.paginate(pageCount: 4, isLandscape: allPortrait, override: override, coverOffset: false)
        #expect(s == [
            Spread(pages: [0]),
            Spread(pages: [1]),
            Spread(pages: [2, 3]),
        ])
    }

    @Test func forcePairOnLandscapePage() {
        // 4 ページ全横長・page 0,1 を forcePair・表紙オフセット無し
        // [0,1](forcePair で 2 枚), [2](横長単独), [3](横長単独)
        let landscape: (Int) -> Bool = { _ in true }
        let override: (Int) -> PageLayoutOverride? = { ($0 == 0 || $0 == 1) ? .forcePair : nil }
        let s = SpreadPaginator.paginate(pageCount: 4, isLandscape: landscape, override: override, coverOffset: false)
        #expect(s == [
            Spread(pages: [0, 1]),
            Spread(pages: [2]),
            Spread(pages: [3]),
        ])
    }

    @Test func allLandscapeEverySolo() {
        let landscape: (Int) -> Bool = { _ in true }
        let s = SpreadPaginator.paginate(pageCount: 3, isLandscape: landscape, override: noOverride, coverOffset: false)
        #expect(s == [Spread(pages: [0]), Spread(pages: [1]), Spread(pages: [2])])
    }

    @Test func coverOffsetWinsOverPage0Landscape() {
        // page 0 が横長でも coverOffset:true なら表紙は単独 [0]、以降通常ペア
        let landscape: (Int) -> Bool = { $0 == 0 }
        let s = SpreadPaginator.paginate(pageCount: 5, isLandscape: landscape, override: noOverride, coverOffset: true)
        #expect(s == [Spread(pages: [0]), Spread(pages: [1, 2]), Spread(pages: [3, 4])])
    }

    @Test func coverOffsetYieldsToPage0ForcePair() {
        // page 0 に forcePair を付けると coverOffset の表紙単独より優先され、表紙が次ページとペアになる
        let override: (Int) -> PageLayoutOverride? = { $0 == 0 ? .forcePair : nil }
        let s = SpreadPaginator.paginate(pageCount: 5, isLandscape: allPortrait, override: override, coverOffset: true)
        #expect(s == [Spread(pages: [0, 1]), Spread(pages: [2, 3]), Spread(pages: [4])])
    }
}
