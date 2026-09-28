// SPDX-License-Identifier: MIT
import AppKit
import Testing
@testable import StackNest

@Suite("G57: フォントパネルの橋渡し") @MainActor
struct FontPanelBridgeTests {
    @Test func modesAreCollectionAndFaceOnly() {
        #expect(FontPanelBridge.shared.validModesForFontPanel(NSFontPanel.shared) == [.collection, .face])
    }

    /// G57: `NSFontManager.convert(_:)`（`familyName(from:)` の実装）は、実機のフォントパネルで
    /// 利用者が実際にクリックしたときの差分にしか追従しない。ヘッドレスなテスト実行では
    /// `setSelectedFont` だけでは convert の内部状態が更新されず（`selectedFont` は "Georgia" に
    /// なるが `convert(...).familyName` は変わらない＝2026-09-28 に確認）、直接 "Georgia" を
    /// 期待することができない。ここでは配線（`changeFont` が `familyName(from:)` の値をそのまま
    /// `onPick` へ運ぶこと）だけを確かめる。実際の書体名が届くことは実機 smoke で確認する。
    @Test func pickDeliversFamilyName() {
        var picked: [String] = []
        FontPanelBridge.shared.open(current: nil) { picked.append($0) }
        NSFontManager.shared.setSelectedFont(NSFont(name: "Georgia", size: 14)!, isMultiple: false)
        FontPanelBridge.shared.changeFont(NSFontManager.shared)
        #expect(picked == [FontPanelBridge.shared.familyName(from: NSFontManager.shared)].compactMap { $0 })
        #expect(!picked.isEmpty)
        NSFontPanel.shared.orderOut(nil)
    }
}
