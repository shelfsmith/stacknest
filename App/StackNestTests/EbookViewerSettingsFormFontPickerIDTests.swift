// SPDX-License-Identifier: MIT
import Testing
@testable import StackNest

/// fix (2026-09-29): 設定 ▸ 内蔵ビューア ▸ 電子書籍ビューアで、和文・欧文どちらの書体
/// Picker も欧文側になって表示されていた（和文 Picker が消える）不具合の再発防止。
///
/// 原因は `EbookViewerSettingsForm.fontPicker(_:candidates:value:)` の2つの呼び出し
/// （和文・欧文）が、どちらも `.id(fontPanelRevision)` という**同じ**明示 id を使っていたこと。
/// `Form` はこれを同一ビューとみなし、後に評価された欧文 Picker が和文 Picker の位置にも
/// 描画されていた。
///
/// 実 `Form`/`Picker` の描画結果（どちらが実際に表示されるか）は、ヘッドレスな App テストの
/// 環境（ウィンドウなし・レイアウトパスなし）では信頼して検証できない
/// （`IntegrityWindowLogicTests`/`LocalControlControllerOpenSerializationTests` が同じ理由で
/// 実 `NSWindow`/実ビューのインスタンス化を避けている）。そのため、実際にバグを生んだ
/// 「id が両スロットで一致するかどうか」という純粋な入力を検証する。
@Suite("EbookViewerSettingsForm.fontPickerID (dup-picker fix, 2026-09-29)")
struct EbookViewerSettingsFormFontPickerIDTests {
    @Test("同じ revision でも和文と欧文の id は異なる")
    func differsBetweenSlotsAtSameRevision() {
        let japanese = EbookViewerSettingsForm.fontPickerID(slot: .japanese, revision: 0)
        let latin = EbookViewerSettingsForm.fontPickerID(slot: .latin, revision: 0)
        #expect(japanese != latin, "和文と欧文の Picker が同じ id だと Form が同一視し、後勝ちで一方が消える")
    }

    @Test("同じスロットでも revision が変われば id が変わる（「その他…」選択後の作り直し）")
    func changesWithRevisionForSameSlot() {
        let before = EbookViewerSettingsForm.fontPickerID(slot: .japanese, revision: 0)
        let after = EbookViewerSettingsForm.fontPickerID(slot: .japanese, revision: 1)
        #expect(before != after)
    }

    @Test("4通りの組み合わせがすべて異なる id を持つ（スロット×revision の直積で衝突が無い）")
    func allCombinationsAreDistinct() {
        let ids = [
            EbookViewerSettingsForm.fontPickerID(slot: .japanese, revision: 0),
            EbookViewerSettingsForm.fontPickerID(slot: .latin, revision: 0),
            EbookViewerSettingsForm.fontPickerID(slot: .japanese, revision: 1),
            EbookViewerSettingsForm.fontPickerID(slot: .latin, revision: 1),
        ]
        #expect(Set(ids).count == ids.count)
    }
}
