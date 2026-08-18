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

    /// ★ 本題: 更新し続けても上限で書かれる。
    ///
    /// **feeder は assertion の待ち窓（10 秒）より確実に長く（12 秒）動き続ける。**
    /// これが G37 コントローラのレビューで指摘された穴の修正点: 旧版は feeder が
    /// 待ち窓より先に止まっていたため、上限を無効化しても「feeder 停止後に
    /// 通常の `interval` が自然発火する」ことで PASS してしまっていた（上限の
    /// 回帰ガードになっていなかった）。
    ///
    /// feeder の周期（100ms）は `interval`（500ms）より十分短いので、feeder が
    /// 動き続けている限り `interval` 基準のタイマは**原理的に**一度も満了しない
    /// （schedule のたびに締切が張り直されるため）。したがって「待ち窓の中で
    /// 書き込みが起きる」ことは、上限（`maxDelay`）の存在**だけ**に依存する。
    ///
    /// 待ち窓を 10 秒まで広げたのは実測に基づく: `maxDelay` の実測期待発火は ~300ms 後だが、
    /// フルスイート並列実行（1985 テスト・340 suites）下ではスレッドプール輻輳により
    /// 2 秒の窓では 60% 前後の頻度で偽陰性になった。3 秒でも 30〜40% 落ちた（`maxDelay=600ms`
    /// 時点の実測）。10 秒では 15 回連続で輻輳を吸収できることを確認済み（報告書参照）。
    @Test("更新を続けても上限に達したら書かれる")
    func writesOnceTheDeadlineCapIsReached() async throws {
        let c = Counter()
        let d = SettingsWriteDebouncer(interval: .milliseconds(500), maxDelay: .milliseconds(300))

        let feeder = Task.detached {
            for _ in 0..<120 {                                 // 100ms × 120 = 12 秒、待ち窓（10 秒）より長い
                if Task.isCancelled { break }
                d.schedule(key: "k") { c.bump() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        #expect(c.waitForWrite(timeout: 10), "上限に達した時点で書き込みが起きること")
        feeder.cancel()
        await feeder.value
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

    /// ★ キーごとに初回時刻を持つこと。
    /// 片方のキーを連続更新し続けても、**もう片方は自分の上限で書かれる**。
    ///
    /// `writesOnceTheDeadlineCapIsReached` と同じ理由で、`busy` の feeder は
    /// 待ち窓（10 秒）より確実に長く（12 秒）動き続ける。`busy` が interval より
    /// 短い周期で回り続ける限り共有タイマは原理的に自然発火しないので、
    /// `quiet` が待ち窓の中で書かれるかどうかは上限の有無だけで決まる
    /// （待ち窓の長さの理由は上記 `writesOnceTheDeadlineCapIsReached` のコメント参照）。
    @Test("連続更新していないキーが巻き添えで遅れない")
    func aQuietKeyIsNotStarvedByABusyOne() async throws {
        let quiet = Counter()
        let busy = Counter()
        let d = SettingsWriteDebouncer(interval: .milliseconds(500), maxDelay: .milliseconds(300))

        d.schedule(key: "quiet") { quiet.bump() }        // 最初に 1 度だけ
        let feeder = Task.detached {
            for _ in 0..<120 {                           // 100ms × 120 = 12 秒、待ち窓（10 秒）より長い
                if Task.isCancelled { break }
                d.schedule(key: "busy") { busy.bump() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        #expect(quiet.waitForWrite(timeout: 10), "静かなキーが上限で書かれること")
        feeder.cancel()
        await feeder.value
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
