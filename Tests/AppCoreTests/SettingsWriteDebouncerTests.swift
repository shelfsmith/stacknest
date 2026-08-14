// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G36 ③: 連続発火する設定書き込みをまとめる。
///
/// `columnWidths`（列ドラッグ中）・`gridItemSize`（Slider 直結）・
/// `windowFrame`（`didResize`/`didMove`）は**ドラッグ中ずっと発火**し、
/// 1 イベントごとに commit + fsync していた（1 操作 36〜80ms のストレージ）。
///
/// **遅らせるのはディスクへの書き込みだけ。** メモリ上の値は即時更新されるので
/// UI の見た目は変わらない。
@Suite("SettingsWriteDebouncer（G36）")
struct SettingsWriteDebouncerTests {

    /// 書き込み回数を数える箱（オフスレッドからも触れるように）。
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }

    @Test("連続した更新は 1 回の書き込みに畳まれる")
    func coalescesRapidUpdates() async throws {
        let counter = Counter()
        let d = SettingsWriteDebouncer(interval: .milliseconds(100))

        for _ in 0..<20 {
            d.schedule(key: "columnWidths") { counter.bump() }
        }

        #expect(counter.count == 0, "まだ書かれていない")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(counter.count == 1, "20 回の更新が 1 回の書き込みに畳まれる")
    }

    @Test("キーが違えばそれぞれ 1 回ずつ書かれる")
    func keysAreIndependent() async throws {
        let counter = Counter()
        let d = SettingsWriteDebouncer(interval: .milliseconds(100))

        d.schedule(key: "columnWidths") { counter.bump() }
        d.schedule(key: "windowFrame") { counter.bump() }

        try? await Task.sleep(for: .milliseconds(400))
        #expect(counter.count == 2)
    }

    /// ★ ここが最大の落とし穴。遅延書き込みを入れる以上、
    /// 「書かれないまま終わる」経路を塞がないと**設定が保存されない退行**になる。
    @Test("flush で即座に書かれる")
    func flushWritesImmediately() throws {
        let counter = Counter()
        let d = SettingsWriteDebouncer(interval: .seconds(60))   // 待っていたら来ない長さ

        d.schedule(key: "windowFrame") { counter.bump() }
        #expect(counter.count == 0)

        d.flush()

        #expect(counter.count == 1, "flush は待たずに書く")
    }

    @Test("flush 後は保留が残らない")
    func flushClearsPending() throws {
        let counter = Counter()
        let d = SettingsWriteDebouncer(interval: .seconds(60))

        d.schedule(key: "a") { counter.bump() }
        d.schedule(key: "b") { counter.bump() }
        d.flush()

        #expect(counter.count == 2)
        #expect(d.pendingKeys.isEmpty)
        d.flush()
        #expect(counter.count == 2, "二重に書かない")
    }

    /// 実行された書き込みを順に記録する箱。
    ///
    /// **★ ローカルの `var` を `@Sendable` クロージャの中で変更してはいけない** ――
    /// Swift 6 の strict concurrency がコンパイルエラーにする
    /// （"Mutation of captured var in concurrently-executing code"）。必ず箱を使う。
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
        func record(_ v: Int) { lock.lock(); values.append(v); lock.unlock() }
    }

    /// 同じキーを続けて積んだら、**最後の値だけ**が書かれる。
    @Test("同じキーは最後の書き込みだけが実行される")
    func lastWriteWins() async throws {
        let recorder = Recorder()
        let d = SettingsWriteDebouncer(interval: .milliseconds(100))

        for i in 1...5 {
            d.schedule(key: "k") { recorder.record(i) }
        }
        try? await Task.sleep(for: .milliseconds(400))

        #expect(recorder.all == [5], "最後に積んだものだけが実行される")
    }

    /// ★ C1 の回帰ガード（レビュー指摘）。
    ///
    /// タイマ発火の `flush()` が**古い値**の書き込みを実行中（fsync を模した長い sleep）に、
    /// 別スレッドから**新しい値**が `schedule` され、その直後に明示的な `flush()`（アプリ終了時
    /// に相当）が呼ばれる状況を再現する。
    ///
    /// 修正前は drain のみがロックで直列化され、write の**実行**は直列化されていなかったため、
    /// 速い新しい write が先に完了し、その後で遅い古い write が完了して**新しい値を踏み潰す**
    /// （記録順序が `[2, 1]` になる＝最後に書かれた値が古い方）。
    ///
    /// 修正後は drain+execute を単一の直列キューの 1 タスクとして扱うため、明示的な `flush()`
    /// は先行する（タイマ発火の）write の完了を待ってから実行され、記録順序は必ず `[1, 2]`
    /// になる＝最後に書かれた値が新しい方。
    ///
    /// ★ N1（レビュー再指摘）: 当初は「タイマが 80ms 以内に発火する」ことを固定 sleep で
    /// 仮定していたが、負荷次第でタイマ発火が間に合わず、write1 がまだ drain されていない
    /// うちに write2 の `schedule` が pending の write1 を**単に上書き**してしまい
    /// （＝それ自体は正しい coalescing 動作）、`recorder.all == [2]` で spurious FAIL する
    /// ことが実測で 25% 発生した。固定時間の代わりに `DispatchSemaphore` で
    /// 「write1 が実際に drain されて実行を開始したこと」を確定させてから write2 を積む。
    @Test("同一キーへの並行 flush は完了順序が入れ替わらない（C1 回帰）")
    func concurrentFlushesPreserveCompletionOrder() throws {
        let recorder = Recorder()
        let d = SettingsWriteDebouncer(interval: .milliseconds(30))
        let write1Started = DispatchSemaphore(value: 0)

        // 古い値: タイマ発火で drain され、実行開始を signal してから約 200ms かかる（fsync を模す）。
        d.schedule(key: "k") {
            write1Started.signal()
            Thread.sleep(forTimeInterval: 0.2)
            recorder.record(1)
        }

        // write1 が「実際に drain されて実行中」になったことを確定させてから進む
        // （固定 sleep ではなくイベント同期。踏み外しても無限に固まらないよう 3 秒でタイムアウト。
        // `DispatchSemaphore.wait` は async コンテキストから直接呼べないため、このテストは
        // 意図的に非 async にしている）。
        let write1ActuallyStarted = write1Started.wait(timeout: .now() + 3.0) == .success
        #expect(write1ActuallyStarted, "write1 が 3 秒以内に実行開始しなかった（タイマ遅延が異常）")

        // 新しい値: 古い write が実行中であることが確定した状態で積む。
        d.schedule(key: "k") { recorder.record(2) }

        // アプリ終了時に相当する明示的 flush。別スレッドから、待たずに叩く。
        let flushThread = Thread {
            d.flush()
        }
        flushThread.start()

        // 両方の write が完了するのを待つ。
        Thread.sleep(forTimeInterval: 0.5)

        #expect(
            recorder.all == [1, 2],
            "古い write (1) が完了してから新しい write (2) が実行される必要がある。実際の記録順序: \(recorder.all)"
        )
    }

    /// `deinit` は公開挙動（ドキュメントコメントで「アプリ終了時・ライブラリを閉じるときに
    /// 必ず flush() すること」と謳っている安全網の最後の砦）だが、修正前はテストが 0 件だった。
    @Test("deinit で保留中の write が実行される")
    func deinitFlushesPendingWrites() {
        let counter = Counter()
        do {
            let d = SettingsWriteDebouncer(interval: .seconds(60))
            d.schedule(key: "x") { counter.bump() }
            // `d` はここでスコープを抜け、他に強参照が無いので deinit が同期的に走る。
        }
        #expect(counter.count == 1, "スコープを抜けて deinit されると保留中の write が実行される")
    }

    /// `flush()` は内部でタイマを nil に戻すが、その後の `schedule` が正しく新しいタイマを
    /// 再武装できることを確認する（flush 中/直後に積まれた分が失われないこと）。
    @Test("flush 後の schedule はタイマを再武装できる")
    func scheduleAfterFlushRearmsTimer() async throws {
        let counter = Counter()
        let d = SettingsWriteDebouncer(interval: .milliseconds(100))

        d.schedule(key: "k") { counter.bump() }
        d.flush()
        #expect(counter.count == 1)

        d.schedule(key: "k") { counter.bump() }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(counter.count == 2, "flush 後の schedule でもタイマが再武装され、書き込みが実行される")
    }
}
