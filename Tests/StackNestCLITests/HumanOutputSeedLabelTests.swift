// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI
import StackNestL10n
@testable import StackNestCLI

/// G55 最終レビュー item 5: 人向けの出力では、種まきした既定の名前（保存値は日本語のまま）を
/// 画面と同じく訳して見せる。`--json` はサーバの JSON をそのまま出すので保存値のまま（別テスト）。
/// 並行テストのため `processDefault` には触れず、`$requestOverride.withValue` で言語を切り替える。
@Suite("CLI human output localizes seeded names (G55)")
struct HumanOutputSeedLabelTests {
    private func grant(_ label: String) -> GrantDTO {
        GrantDTO(id: "g1", label: label, token: "t", tier: .read, scope: .all)
    }

    @Test("grant list: 既定ラベルは en で訳し、ja と利用者の名前はそのまま")
    func grantListLine() {
        L10nLang.$requestOverride.withValue(.en) {
            #expect(GrantList.humanLine(grant("(既定) 閲覧")) == "g1\tread\t(Default) View\t[all]")
            #expect(GrantList.humanLine(grant("(既定) 編集")) == "g1\tread\t(Default) Edit\t[all]")
            #expect(GrantList.humanLine(grant("家族")) == "g1\tread\t家族\t[all]")
        }
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(GrantList.humanLine(grant("(既定) 閲覧")) == "g1\tread\t(既定) 閲覧\t[all]")
        }
    }

    @Test("shelves: お気に入り棚（kind=favorites）は en で Favorites、他の棚は名前のまま")
    func shelvesLine() {
        let fav = ShelfDTO(id: 1, title: "お気に入り", kind: "favorites", isSmart: false)
        let user = ShelfDTO(id: 2, title: "お気に入り", kind: "user", isSmart: false)
        let smart = ShelfDTO(id: 3, title: "未読", kind: "user", isSmart: true)
        L10nLang.$requestOverride.withValue(.en) {
            #expect(Shelves.humanLine(fav) == "1\tFavorites\t[user]")
            #expect(Shelves.humanLine(user) == "2\tお気に入り\t[user]")
            #expect(Shelves.humanLine(smart) == "3\t未読\t[smart]")
        }
        L10nLang.$requestOverride.withValue(.ja) {
            #expect(Shelves.humanLine(fav) == "1\tお気に入り\t[user]")
        }
    }
}
