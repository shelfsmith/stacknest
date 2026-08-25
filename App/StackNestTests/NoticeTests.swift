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
    ///
    /// **固定時間で待たない。**「対象のタイマーがこの環境で発火し終わったか」を
    /// **別の枠で実際に観測**してから判定する。負荷が高くて発火が遅れただけの状況で
    /// 「まだ在る＝合格」と誤判定するのを防ぐ（変異注入 5 回中 1 回すり抜けた実測がある）。
    ///
    /// **対象（warned・仮に guard が壊れて動いた場合の締切）は 30ms、見張りは 60ms**
    /// と締切を分けてある。同じ 30ms 同士だと「見張りが消えた」が「対象のタイマーも
    /// 発火し終えた」を**厳密には含意しない**（同一 MainActor 上の 2 つの Task が
    /// 同じ長さのスリープから同じ順序で目覚める保証はない）。見張りを対象より長くすれば、
    /// 見張りの 60ms が経過した時点で対象の 30ms は壁時計上必ず経過済みなので、
    /// 論理的に含意する形になる。
    @Test("warning は時間で消えない")
    @MainActor
    func warningStays() async throws {
        let warned = NoticeSlot()
        let canary = NoticeSlot()
        warned.present(Notice(kind: .warning, text: "2 件失敗", detail: "…"),
                       autoDismissAfter: .milliseconds(30))
        canary.present(Notice(kind: .info, text: "見張り", detail: nil),
                       autoDismissAfter: .milliseconds(60))

        // 見張りが消えた ＝ 見張りより短い対象のタイマーは、壁時計上すでに発火し終えている。
        let deadline = Date().addingTimeInterval(3)
        while canary.notice != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(canary.notice == nil, "前提: 60ms のタイマーが発火し終えていること")

        #expect(warned.notice != nil, "警告が勝手に消えた")
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
    ///
    /// **canary 事象同期にしてある**（`warningStays` と同じ方式）。以前は固定 3 秒の
    /// ポーリング上限を否定的な主張（「消えないこと」）に使っていたため、**正しい実装のときは
    /// 必ず 3 秒を実消費**していた（172 本中このテストだけ突出して遅い）。対象（前の info の
    /// 30ms タイマー、もし解除し損ねていれば発火する）より**長い 60ms の見張りタイマー**を
    /// 別の枠に張り、見張りが消えるのを待ってから判定する。見張りの 60ms が経過した時点で
    /// 対象の 30ms は壁時計上必ず発火し終えているので、「見張りが消えた」は「対象のタイマーが
    /// あれば既に発火している」を論理的に含意する（`warningStays` と揃えて締切を分ける理由も同じ）。
    @Test("新しいお知らせは前のタイマーを止める")
    @MainActor
    func presentingAgainCancelsThePreviousTimer() async throws {
        let slot = NoticeSlot()
        let canary = NoticeSlot()
        slot.present(Notice(kind: .info, text: "先", detail: nil),
                     autoDismissAfter: .milliseconds(30))
        slot.present(Notice(kind: .warning, text: "後", detail: nil),
                     autoDismissAfter: .milliseconds(30))
        canary.present(Notice(kind: .info, text: "見張り", detail: nil),
                       autoDismissAfter: .milliseconds(60))

        let deadline = Date().addingTimeInterval(3)
        while canary.notice != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(canary.notice == nil, "前提: 60ms のタイマーが発火し終えていること")

        #expect(slot.notice?.text == "後", "前の info のタイマーが後の警告を消した")
    }
}
