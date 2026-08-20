// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

/// G38 smoke A5: ヘルプ表にルーペが載ること。
/// 表はバインドから生成されるので `ViewerAction` に足しただけで載る「はず」だが、
/// 実機のヘルプは数秒で自動的に消えて目視確認が安定しなかったので、ここで固定する。
@Suite("ヘルプ表のルーペ行（G38 smoke A5）")
struct ViewerHelpLoupeRowTests {
    @Test func defaultsPutTheLoupeInTheZoomSectionWithItsKey() {
        let grouped = ViewerHelpRows.makeGrouped(from: .defaults)

        let zoom = grouped.first { $0.section == ViewerActionSection.zoom.title }
        #expect(zoom != nil, "ズームの節が存在すること")

        let loupe = zoom?.rows.first { $0.action == "ルーペ" }
        #expect(loupe != nil, "ルーペはズームの節に載る（spec の分類）")
        #expect(loupe?.keys == "l", "既定キー l が表に出ること")
    }

    /// キーを再割当したら、表もそれに追従する（表がバインドから生成されている証拠）。
    @Test func theRowFollowsARebind() {
        var bindings = ViewerKeyBindings.defaults
        bindings.remove(.character("l"), from: .toggleLoupe)
        _ = bindings.assign(.character("m"), to: .toggleLoupe)

        let rows = ViewerHelpRows.make(from: bindings)
        let loupe = rows.first { $0.action == "ルーペ" }
        #expect(loupe?.keys == "m", "再割当が表に反映されること")
    }
}
