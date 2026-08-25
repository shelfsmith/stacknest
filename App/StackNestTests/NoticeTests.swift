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

        // ★ 固定時間で判定しない。**消えるまで待つ**（混んでいて遅れただけ、で落とさないため）。
        // 締切を過ぎても消えなければ本物の失敗。
        let deadline = Date().addingTimeInterval(3)
        while slot.notice != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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

        // ★ この主張は否定的（「勝手に消えないこと」）なので、待ち時間を延ばしても
        // 正しい実装側が誤って落ちる方向にはならない（cancel は present() 内で同期的に
        // 行われるので、正しければ notice は自発的に変化しない）。一方で、前の info の
        // タイマーが解除し損ねている壊れ方（あるいは guard 欠落で新しい warning にも
        // タイマーが張られる壊れ方）を確実に捕まえるには、CPU が混んでいても 30ms の
        // タイマーが発火しきるだけの時間を確保する必要がある——Step 3 でフルスイート
        // 並列実行下では 300ms 固定待ちで実際に不足する例が出た。そこで「変化した瞬間に
        // 即座に検知」しつつ、上限は余裕を持って 3 秒までポーリングする。
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, slot.notice?.text == "後" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(slot.notice?.text == "後", "前の info のタイマーが後の警告を消した")
    }
}
