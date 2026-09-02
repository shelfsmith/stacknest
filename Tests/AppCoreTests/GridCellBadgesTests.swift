// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("グリッドセルの印と著者行")
struct GridCellBadgesTests {
    @Test("未読のときだけ緑丸を出す")
    func unseenOnly() {
        #expect(GridCellBadges.derive(favorited: false, unseen: true).showUnseen == true)
        #expect(GridCellBadges.derive(favorited: false, unseen: false).showUnseen == false)
    }

    @Test("お気に入りはハート。未読と独立")
    func favoriteIndependent() {
        let b = GridCellBadges.derive(favorited: true, unseen: false)
        #expect(b.showFavorite == true)
        #expect(b.showUnseen == false)
        let both = GridCellBadges.derive(favorited: true, unseen: true)
        #expect(both.showFavorite == true && both.showUnseen == true)
    }

    @Test("著者が nil でも行は消えない（空文字を返す）")
    func authorLineReservesRow() {
        #expect(gridAuthorLine(nil) == "")
        #expect(gridAuthorLine("") == "")
        #expect(gridAuthorLine("作者") == "作者")
    }
}
