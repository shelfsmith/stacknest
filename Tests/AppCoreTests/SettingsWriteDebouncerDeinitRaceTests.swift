// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G36 ③ Task 6 追加調査: `deinit { flush() }`（`SettingsWriteDebouncer.swift:43`）は、
/// `LibrarySettings` が保留中の書き込みを持ったまま解放されたときの**同期的な安全網として
/// 当てにできるか**を実測する。
///
/// ## 背景（レビューで出た懸念）
///
/// タイマのハンドラは `t.setEventHandler { [weak self] in self?.flush() }` という形で
/// `self` を弱参照している。ハンドラが実行中の間、`self?` の評価は `self` を**一時的に
/// 強参照へ昇格**させる（そうしないと `flush()` の実行中に `self` が解放されて
/// use-after-free になる）。この昇格は `flush()` 呼び出しが返るまで生き続ける。
///
/// つまり、タイマのハンドラが「飛行中」（write を実行中）のときに、所有者
/// （`LibrarySettings`）側が唯一の外部強参照を手放しても、`SettingsWriteDebouncer` の
/// 参照カウントはこの一時強参照のぶんだけ残っており、**その瞬間には 0 にならない** ――
/// つまり `deinit` はそのタイミングでは走らない。`deinit` が実際に走るのは、ハンドラが
/// 戻って一時強参照が外れた**後**（＝write 自体はもう完了した後）になる。
///
/// この実測が確かめるのは 2 点:
/// 1. **write は失われるか？** → 失われない（後述のとおり、`deinit` が走るころには
///    ハンドラ自身がすでに `drainAndExecute()` を完了させているので、write は
///    「タイマが自然に発火したから」実行される。`deinit` の関与は無い＝no-op になる）。
/// 2. **`LibrarySettings` を解放する側のコード（例: アプリ終了処理）は、write の完了を
///    `deinit` 経由で待てるか？** → **待てない**。強参照を手放す操作（スコープ離脱・
///    `nil` 代入）はブロックせずに即座に戻り、write は別スレッド（debounce queue）上で
///    非同期に完了する。呼び出し元には write が完了したという**同期的な保証が一切無い**。
///
/// これが Task 7（アプリ終了時・`closeBundle` での明示的 `flushPendingWrites()` 呼び出し）
/// が**推測ではなく実測で必須**と言える理由: プロセスが `deinit` 完了前に終了すれば、
/// この経路では write が本当に失われうる。`flush()` を明示的に呼んで初めて
/// 「呼び出しが return した時点で write は完了している」という同期保証が得られる
/// （`SettingsWriteDebouncer.swift` の `flush()` のドキュメントコメントどおり）。
///
/// ★ 固定 sleep は使わない。`DispatchSemaphore` で「write が実際に実行開始したこと」
/// を確定させてから強参照を手放し、write の完了も `counter` の変化をポーリングで
/// 検出する（`SettingsWriteDebouncerTests.swift` の C1 回帰テストと同じ手法）。
@Suite("SettingsWriteDebouncer deinit backstop の実測（G36 ③ Task 6 追加調査）")
struct SettingsWriteDebouncerDeinitRaceTests {

    /// 書き込み完了を数える箱（オフスレッドからも触れるように）。
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }

    @Test("write が飛行中に唯一の強参照を手放しても、write の完了は保証されない（deinit は同期バックストップではない）")
    func droppingLastReferenceDoesNotBlockUntilInFlightWriteCompletes() throws {
        let counter = Counter()
        let writeStarted = DispatchSemaphore(value: 0)
        let writeMayFinish = DispatchSemaphore(value: 0)

        do {
            // 短い interval でタイマをすぐ発火させ、「飛行中」の状態を作りやすくする。
            let d = SettingsWriteDebouncer(interval: .milliseconds(5))
            d.schedule(key: "k") {
                // タイマのハンドラ（= self? による一時強参照が生きている区間）の中で
                // 実行される。実際の fsync の代わりに、意図的にここでブロックする。
                writeStarted.signal()
                _ = writeMayFinish.wait(timeout: .now() + 3.0)
                counter.bump()
            }

            // タイマが実際に発火し、write の実行が始まった（= self? が一時的に
            // 強参照へ昇格した状態）ことを event で確定させる。固定 sleep は使わない。
            let started = writeStarted.wait(timeout: .now() + 3.0) == .success
            #expect(started, "タイマが 3 秒以内に発火しなかった（テスト環境の異常）")

            // ここで `d`（このスコープが持つ唯一の外部強参照）を手放す。
            // write はまだ writeMayFinish 待ちでブロックされているので、
            // デバウンサの参照カウントは「一時強参照」のぶんだけ残っているはず
            // （= このスコープを抜けても deinit はまだ走らない、という理論の検証）。
        }

        // スコープを抜けた直後の時点。write はまだ `writeMayFinish` 待ちで止めてある。
        // もし「強参照を手放す」操作が deinit 経由で write の完了を待つ（＝同期バックストップ
        // として機能する）なら、この時点で既に write は完了しているはずだが、そうはならない
        // ――「手放す」操作自体はブロックせず、write は別スレッドで止まったままである。
        #expect(
            counter.count == 0,
            "強参照を手放す操作は write の完了をブロックして待たない（＝ deinit は呼び出し元にとって同期的な安全網ではない）"
        )

        // ここでようやく write を進行させる（現実には fsync が完了する場面に相当）。
        writeMayFinish.signal()

        // write が実際に完了する（counter が動く）のを event ベースでポーリング確認する。
        let deadline = Date().addingTimeInterval(3.0)
        while counter.count == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(
            counter.count == 1,
            "write 自体は失われない ―― タイマが既に発火していたので、deinit の関与なしにハンドラ自身が drainAndExecute() を完了させる"
        )
    }

    /// 対照実験: タイマが**まだ一度も発火していない**（＝一時強参照が存在しない）通常運用の
    /// 状態でスコープを抜けた場合は、`deinit` が同期的に走り、`flush()` が保留中の write を
    /// その場で実行する。この対照ケースはすでに `SettingsWriteDebouncerTests.swift` の
    /// `deinitFlushesPendingWrites()`（Task 5, interval 60 秒）でカバーされているが、
    /// ここでは「タイマが発火する前に確実にスコープを抜けられる」ことを
    /// 同じ手法（`schedule` 直後に即スコープを抜ける）で再確認し、上のケースとの対比を明確にする。
    @Test("write がまだ飛行中でなければ、deinit がその場で同期的に書く")
    func deinitFlushesSynchronouslyWhenNoTimerIsInFlight() throws {
        let counter = Counter()
        do {
            // interval を長く取り、タイマが発火する前に確実にスコープを抜けられるようにする。
            let d = SettingsWriteDebouncer(interval: .seconds(60))
            d.schedule(key: "k") { counter.bump() }
            // `d` はここでスコープを抜ける。他に強参照は無いので deinit が同期的に走る。
        }
        #expect(
            counter.count == 1,
            "タイマが発火する前に唯一の参照を手放した場合は、deinit がその場で write を実行する"
        )
    }
}
