// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ViewerModel spread")
@MainActor
struct ViewerModelSpreadTests {
    /// 7 ページ・表紙独立の見開き: [0],[1,2],[3,4],[5,6]
    private func makeSpreadModel(behavior: EndOfBookBehavior = .stop) -> ViewerModel {
        let m = ViewerModel(pageCount: 7, options: ViewerOptions(pageDirection: .rightToLeft, endOfBookBehavior: behavior))
        m.setDisplayMode(.spread)
        m.setSpreads([
            Spread(pages: [0]),
            Spread(pages: [1, 2]),
            Spread(pages: [3, 4]),
            Spread(pages: [5, 6]),
        ])
        return m
    }

    @Test func advanceMovesAcrossSpreads() {
        let m = makeSpreadModel()
        #expect(m.currentSpreadIndex == 0)
        #expect(m.currentPage == 0)
        #expect(m.advance() == .moved)
        #expect(m.currentSpreadIndex == 1)
        #expect(m.currentPage == 1)   // spread [1,2] の先頭
        #expect(m.advance() == .moved)
        #expect(m.currentPage == 3)
    }

    @Test func goBackMovesAcrossSpreads() {
        let m = makeSpreadModel()
        m.advance(); m.advance()       // spread index 2, page 3
        #expect(m.currentSpreadIndex == 2)
        m.goBack()
        #expect(m.currentSpreadIndex == 1)
        #expect(m.currentPage == 1)
        m.goBack()
        #expect(m.currentSpreadIndex == 0)
        #expect(m.currentPage == 0)
        m.goBack()                     // 先頭クランプ
        #expect(m.currentSpreadIndex == 0)
    }

    @Test func advanceAtEndStop() {
        let m = makeSpreadModel(behavior: .stop)
        m.goLast()
        #expect(m.currentSpreadIndex == 3)
        #expect(m.advance() == .endStop)
        #expect(m.currentSpreadIndex == 3)  // 動かない
    }

    @Test func advanceAtEndLoop() {
        let m = makeSpreadModel(behavior: .loop)
        m.goLast()
        #expect(m.advance() == .endLoop)
        #expect(m.currentSpreadIndex == 0) // 先頭へ
        #expect(m.currentPage == 0)
    }

    @Test func advanceAtEndNextBook() {
        let m = makeSpreadModel(behavior: .nextBook)
        m.goLast()
        #expect(m.advance() == .endNextBook)
        #expect(m.currentSpreadIndex == 3) // モデルは動かさない（コントローラが次巻処理）
    }

    @Test func progressTextSingleVsSpread() {
        let single = ViewerModel(pageCount: 7)
        single.goTo(page: 2)
        #expect(single.progressText == "3 / 7")

        let m = makeSpreadModel()
        #expect(m.progressText == "1 / 7")        // [0] 単独
        m.advance()
        #expect(m.progressText == "2–3 / 7")      // [1,2]
    }

    @Test func currentSpreadIndexTracking() {
        let m = makeSpreadModel()
        m.goTo(page: 5)              // single ロジックで currentPage=5
        m.setSpreads(m.spreads)     // re-anchor: page 5 を含む見開き [5,6] = index 3
        #expect(m.currentSpreadIndex == 3)
    }

    @Test func singleModeAdvanceUnchanged() {
        let m = ViewerModel(pageCount: 3, options: ViewerOptions(pageDirection: .rightToLeft, endOfBookBehavior: .stop))
        #expect(m.advance() == .moved)
        #expect(m.currentPage == 1)
        m.goLast()
        #expect(m.advance() == .endStop)
        #expect(m.currentPage == 2)
    }

    @Test func isAtLastPageSpreadMode() {
        let m = makeSpreadModel()
        m.advance(); m.advance()            // spread index 2 ([3,4]), currentPage 3
        #expect(m.currentSpreadIndex == 2)
        #expect(m.isAtLastPage == false)    // 最終見開きではない
        m.advance()                         // spread index 3 ([5,6]), currentPage 5
        #expect(m.currentSpreadIndex == 3)
        #expect(m.currentPage == 5)         // pageCount-1 = 6 だが見開き先頭は 5
        #expect(m.isAtLastPage == true)     // 最終見開き（off-by-one を防ぐ）
    }

    @Test func goToReanchorsSpreadIndex() {
        let m = makeSpreadModel()
        m.goTo(page: 5)                     // setSpreads を呼ばずに再アンカーされる
        #expect(m.currentSpreadIndex == 3)  // page 5 を含む見開き [5,6] = index 3
        #expect(m.currentPage == 5)
    }

    @Test func singlePageBookInSpreadMode() {
        let m = ViewerModel(pageCount: 1, options: ViewerOptions(pageDirection: .rightToLeft, endOfBookBehavior: .stop))
        m.setDisplayMode(.spread)
        m.setSpreads([Spread(pages: [0])])
        #expect(m.currentSpreadIndex == 0)
        #expect(m.isAtLastPage == true)
        #expect(m.advance() == .endStop)
        #expect(m.currentSpreadIndex == 0)
        #expect(m.progressText == "1 / 1")
    }

    @Test func emptySpreadsInSpreadMode() {
        let m = ViewerModel(pageCount: 7, options: ViewerOptions(pageDirection: .rightToLeft, endOfBookBehavior: .stop))
        m.setDisplayMode(.spread)            // setSpreads を呼ばない → spreads は空
        m.goLast()                           // no-op
        #expect(m.currentSpreadIndex == 0)
        #expect(m.currentPage == 0)
        #expect(m.advance() == .endStop)     // クラッシュせず末挙動
        #expect(m.currentSpreadIndex == 0)
        #expect(m.currentPage == 0)
        m.goBack()                           // no-op
        #expect(m.currentSpreadIndex == 0)
        #expect(m.isAtLastPage == true)      // 空 spreads は最終扱い
    }
}
