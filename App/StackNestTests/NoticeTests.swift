// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNest

/// お知らせ 1 枠の寿命。
///
/// ★ **「info は消える／warning は消えない」がこのフェーズの中心**で、
/// 呼び出し側にコピーするとずれる規則。だから枠に閉じ、ここで固定する。
///
/// **実時間では待たない**（2026-09-26）。以前は「締め切り 3 秒まで 10ms おきに見る」作りだったが、
/// CI の遅い機械でメインアクターが数秒ふさがると、見張りのループが再開した時点で締め切りを過ぎ、
/// 後ろに並んだ消去のタスクがまだ走っていないだけで落ちた（v0.15.0 の push で 2 回続けて起きた）。
/// 今は `ManualSleeper` を差し込み、**タイマーが待ちに入ったのを数で確かめてから手で時間を進める**。
/// 判定は発火の順序だけで決まり、機械の速さに左右されない。
@Suite("お知らせ 1 枠の寿命（G41）")
struct NoticeSlotTests {

    @Test("info は時間で消える")
    @MainActor
    func infoDisappears() async throws {
        let clock = ManualSleeper()
        let slot = NoticeSlot(sleep: clock.sleeper)
        slot.present(Notice(kind: .info, text: "追加しました", detail: nil))
        #expect(slot.notice != nil, "出した直後は見えていること")

        try await clock.waitUntilPending(1)
        clock.fireAll()
        await settle { slot.notice == nil }
        #expect(slot.notice == nil, "info が消えていない")
    }

    /// ★ 本命。索引無効・取り込み失敗は**見逃したら二度と分からない**。
    /// 警告にはタイマーを張らないこと（待ちが 1 つも登録されない）と、時間を進めても残ることの両方を見る。
    @Test("warning は時間で消えない")
    @MainActor
    func warningStays() async throws {
        let clock = ManualSleeper()
        let warned = NoticeSlot(sleep: clock.sleeper)
        warned.present(Notice(kind: .warning, text: "2 件失敗", detail: "…"))

        await settle { false }   // 仮に誤ってタイマーを張っていれば、ここで待ちに入る
        #expect(clock.pending == 0, "警告に自動消去のタイマーを張っている")
        clock.fireAll()
        await settle { false }
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
    /// 前の info の待ちは登録されたまま残るので、それを発火させても消えないことを見る。
    @Test("新しいお知らせは前のタイマーを止める")
    @MainActor
    func presentingAgainCancelsThePreviousTimer() async throws {
        let clock = ManualSleeper()
        let slot = NoticeSlot(sleep: clock.sleeper)
        slot.present(Notice(kind: .info, text: "先", detail: nil))
        try await clock.waitUntilPending(1)
        slot.present(Notice(kind: .warning, text: "後", detail: nil))

        clock.fireAll()          // 前の info のタイマーを発火させる
        await settle { false }
        #expect(slot.notice?.text == "後", "前の info のタイマーが後の警告を消した")
    }
}

/// 手で進める待ち方。`sleeper` を `NoticeSlot` に渡すと、自動消去のタスクはここで止まり、
/// `fireAll()` を呼ぶまで進まない。
@MainActor
final class ManualSleeper {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 待ちに入っているタイマーの数。
    var pending: Int { waiters.count }

    nonisolated var sleeper: NoticeSlot.Sleeper {
        { [weak self] _ in await self?.suspend() }
    }

    private func suspend() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 待ちに入っているタイマーをすべて発火させる。
    func fireAll() {
        let fired = waiters
        waiters.removeAll()
        for w in fired { w.resume() }
    }

    /// タイマーが待ちに入るまで譲る。回数で打ち切る（実時間は使わない）。
    func waitUntilPending(_ n: Int) async throws {
        for _ in 0..<1_000 where pending < n { await Task.yield() }
        try #require(pending >= n, "自動消去のタイマーが待ちに入らなかった")
    }
}

/// メインアクター上の他のタスク（消去のタスク）が走り切るまで譲る。回数で打ち切る（実時間は使わない）。
@MainActor
private func settle(until done: () -> Bool) async {
    for _ in 0..<200 {
        if done() { return }
        await Task.yield()
    }
}
