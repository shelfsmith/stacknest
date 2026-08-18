// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G37 ②: デバウンスの締切に上限を入れる。
///
/// 500ms は「**最後の変更から**」なので、ドラッグを続けている限りタイマが張り直され、
/// **10 秒ドラッグすれば 10 秒間 1 度も書かれない**。異常終了するとその全部が失われる。
///
/// 上限が効くのは「1 回のドラッグが 2 秒を超えたとき」だけで、列幅・窓リサイズは通常 1〜3 秒。
/// **大半のドラッグでは一度も発動しない。** 10 秒の長い調整でも書き込みは 5 回で、
/// G36 以前の数十〜数百回とは桁が違う。
@Suite("SettingsWriteDebouncer の締切上限（G37 ②）")
struct SettingsWriteDebouncerDeadlineTests {

    /// 実行された書き込みを数える箱。
    /// **ローカルの `var` を `@Sendable` クロージャ内で変更してはいけない**
    /// （Swift 6 strict concurrency がエラーにする）。
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var v = 0
        private let sem = DispatchSemaphore(value: 0)
        var count: Int { lock.lock(); defer { lock.unlock() }; return v }
        func bump() { lock.lock(); v += 1; lock.unlock(); sem.signal() }
        /// 次の書き込みが起きるまで待つ（固定 sleep を使わないため）。
        @discardableResult
        func waitForWrite(timeout: TimeInterval) -> Bool {
            sem.wait(timeout: .now() + timeout) == .success
        }
    }

    /// `key` を一定周期で連続 `schedule` し続ける「駆動源」。
    ///
    /// **`Task.detached` ではなく生の `Thread` を使う（G37 レビュー Important 1 の修正）。**
    /// `waitForWrite` は `DispatchSemaphore.wait` で Swift Concurrency の**協調スレッドプールの
    /// スレッドを同期ブロック**する。旧版は feeder も `Task.detached` で同じプールを要求していたため、
    /// 「待ち手がプールを埋め尽くし、駆動源（feeder の `Task.sleep` 継続）に回すスレッドが無くなる」
    /// という**決定論的なストール**が起こり得た（`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` で再現）。
    /// これは輻輳による確率的な遅延ではなく、同じ有限プールを待ち手と駆動源が奪い合う構造的な問題
    /// だったため、待ち窓をいくら広げても原理的には解消しない。
    ///
    /// 生の `Thread` は協調プールの外側で実行されるので、`waitForWrite` が何本ブロックしていても
    /// 影響を受けない。これにより待ち窓は元の 2 秒に戻せる。
    final class Feeder {
        private let thread: Thread
        init(period: TimeInterval, iterations: Int, action: @escaping () -> Void) {
            thread = Thread {
                for _ in 0..<iterations {
                    if Thread.current.isCancelled { break }
                    action()
                    Thread.sleep(forTimeInterval: period)
                }
            }
            thread.start()
        }
        func stop() { thread.cancel() }
    }

    /// ★ 本題: 更新し続けても上限で書かれる。
    ///
    /// **feeder は assertion の待ち窓（2 秒）より確実に長く（3 秒）動き続ける。** feeder が
    /// 窓の途中で止まると、上限が無くても「止まった後の通常 `interval` 発火」で PASS して
    /// しまい、上限の回帰ガードにならない（G37 コントローラのレビューで指摘された穴）。
    ///
    /// feeder の周期（100ms）は `interval`（500ms）より十分短いので、feeder が動き続けている限り
    /// `interval` 基準のタイマは**原理的に**一度も満了しない（schedule のたびに締切が張り直される
    /// ため）。したがって「待ち窓の中で書き込みが起きる」ことは、上限（`maxDelay`）の存在**だけ**に
    /// 依存する。
    @Test("更新を続けても上限に達したら書かれる")
    func writesOnceTheDeadlineCapIsReached() throws {
        let c = Counter()
        let d = SettingsWriteDebouncer(interval: .milliseconds(500), maxDelay: .milliseconds(300))

        let feeder = Feeder(period: 0.1, iterations: 30) {   // 100ms × 30 = 3.0 秒、待ち窓（2 秒）より長い
            d.schedule(key: "k") { c.bump() }
        }
        defer { feeder.stop() }

        #expect(c.waitForWrite(timeout: 2), "上限に達した時点で書き込みが起きること")
    }

    /// 上限が無い側の挙動（500ms）を壊していないこと。
    @Test("短い更新は従来どおり 500ms でまとまる")
    func shortBurstsStillCoalesce() async throws {
        let c = Counter()
        let d = SettingsWriteDebouncer(interval: .milliseconds(100), maxDelay: .seconds(60))
        for _ in 0..<20 { d.schedule(key: "k") { c.bump() } }
        #expect(c.count == 0, "まだ書かれていない")
        #expect(c.waitForWrite(timeout: 10))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(c.count == 1, "20 回の更新が 1 回に畳まれる")
    }

    /// ★ 連続更新されているキーがあっても、静かなキーが書かれずに残り続けることはない。
    ///
    /// **キーごとに初回時刻を持つこと自体は、このテストでは検証できない**（そして検証対象では
    /// ない）: `drainAndExecute` は全キーをまとめて drain するため、`firstPendingAt` の辞書は
    /// 実質スカラ 1 個と等価で、`min` は常に「drain 後の最初の `schedule` 時刻」になる。
    /// これは欠陥ではなく、実装は目的を**過達成**している ―― 全キー drain のため、静かなキーは
    /// `min(全起点)+maxDelay` で書かれ、これは per-key 実装の「自分の起点+maxDelay」**以下**。
    /// 飢餓は起こり得ない（G37 最終レビュー I2）。
    ///
    /// `writesOnceTheDeadlineCapIsReached` と同じ理由で、`busy` の feeder は待ち窓（2 秒）より
    /// 確実に長く（3 秒）動き続ける。`busy` が interval より短い周期で回り続ける限り共有タイマは
    /// 原理的に自然発火しないので、`quiet` が待ち窓の中で書かれるかどうかは上限の有無だけで決まる。
    ///
    /// **`quiet` は feeder を起動した「後」に schedule する**（G37 レビュー Important 2 の修正）。
    /// 旧版は feeder 起動前に `quiet` を積んでいたため、feeder の起動が何らかの理由で遅れると
    /// `busy` が一度も干渉しないまま `quiet` が通常の `interval` だけで書かれ、テストが
    /// 何も検証せずに空振りで PASS する余地があった。生の `Thread` は起動が実質即時なので
    /// この窓はほぼ閉じるが、schedule の順序を反転させることで構造的にも塞いでおく。
    @Test("連続更新されているキーがあっても静かなキーが書かれずに残り続けることはない")
    func aQuietKeyIsNotStarvedByABusyOne() throws {
        let quiet = Counter()
        let busy = Counter()
        let d = SettingsWriteDebouncer(interval: .milliseconds(500), maxDelay: .milliseconds(300))

        let feeder = Feeder(period: 0.1, iterations: 30) {   // 100ms × 30 = 3.0 秒、待ち窓（2 秒）より長い
            d.schedule(key: "busy") { busy.bump() }
        }
        defer { feeder.stop() }
        d.schedule(key: "quiet") { quiet.bump() }        // busy が動き出した直後に 1 度だけ

        #expect(quiet.waitForWrite(timeout: 2), "静かなキーが上限で書かれること")
    }

    /// `flush()` の契約は変わらない（待たずに即座に全部書く）。
    @Test("flush は上限に関係なく即座に書く")
    func flushStillWritesImmediately() throws {
        let c = Counter()
        let d = SettingsWriteDebouncer(interval: .seconds(60), maxDelay: .seconds(60))
        d.schedule(key: "k") { c.bump() }
        #expect(c.count == 0)
        d.flush()
        #expect(c.count == 1)
    }
}
