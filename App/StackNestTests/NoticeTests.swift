// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNest

/// お知らせ 1 枠の寿命。
///
/// ★ **「info は消える／warning は消えない」がこのフェーズの中心**で、
/// 呼び出し側にコピーするとずれる規則。だから枠に閉じ、ここで固定する。
/// 待ち時間は `autoDismissAfter` で縮める（固定 6 秒待ちのテストにしない）。
@Suite("お知らせ 1 枠の寿命（G41）")
struct NoticeSlotTests {

    @Test("info は時間で消える")
    @MainActor
    func infoDisappears() async throws {
        let slot = NoticeSlot()
        slot.present(Notice(kind: .info, text: "追加しました", detail: nil),
                     autoDismissAfter: .milliseconds(30))
        #expect(slot.notice != nil, "出した直後は見えていること")

        try await Task.sleep(for: .milliseconds(300))
        #expect(slot.notice == nil, "info が消えていない")
    }

    /// ★ 本命。索引無効・取り込み失敗は**見逃したら二度と分からない**。
    @Test("warning は時間で消えない")
    @MainActor
    func warningStays() async throws {
        let slot = NoticeSlot()
        slot.present(Notice(kind: .warning, text: "2 件失敗", detail: "…"),
                     autoDismissAfter: .milliseconds(30))

        try await Task.sleep(for: .milliseconds(300))
        #expect(slot.notice != nil, "警告が勝手に消えた")
    }

    @Test("× で閉じられる")
    @MainActor
    func dismissClearsIt() {
        let slot = NoticeSlot()
        slot.present(Notice(kind: .warning, text: "2 件失敗", detail: nil))
        slot.dismiss()
        #expect(slot.notice == nil)
    }

    /// 新しいお知らせを出したら、前のタイマーは止まっていること。
    /// 止まっていないと、**後から出した警告を前の info のタイマーが消してしまう**。
    @Test("新しいお知らせは前のタイマーを止める")
    @MainActor
    func presentingAgainCancelsThePreviousTimer() async throws {
        let slot = NoticeSlot()
        slot.present(Notice(kind: .info, text: "先", detail: nil),
                     autoDismissAfter: .milliseconds(30))
        slot.present(Notice(kind: .warning, text: "後", detail: nil),
                     autoDismissAfter: .milliseconds(30))

        try await Task.sleep(for: .milliseconds(300))
        #expect(slot.notice?.text == "後", "前の info のタイマーが後の警告を消した")
    }
}
