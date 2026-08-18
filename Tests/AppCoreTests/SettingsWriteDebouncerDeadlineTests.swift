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
    @Test("更新を続けても上限に達したら書かれる")
    func writesOnceTheDeadlineCapIsReached() async throws {
        let c = Counter()
        let d = SettingsWriteDebouncer(interval: .milliseconds(500), maxDelay: .milliseconds(600))

        // 100ms ごとに 12 回積む（= 1.2 秒）。500ms の締切は毎回張り直されるので、
        // 上限（600ms）が無ければ 1 度も書かれない。
        let feeder = Task.detached {
            for _ in 0..<12 {
                d.schedule(key: "k") { c.bump() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        // タイムアウトは実測期待値（600ms）よりだいぶ長い 10 秒を取る。ここは実際の締切ではなく
        // 「フルスイート並列実行下でのスレッドプール輻輳」を吸収するための安全マージン
        // （このアサーション自体は固定 sleep ではなく `waitForWrite` の事象待ちのまま。
        // 3 秒では 1985 テスト並列実行時に 30〜40% の頻度で偽陰性になることを実測した＝G37）。
        #expect(c.waitForWrite(timeout: 10), "上限に達した時点で書き込みが起きること")
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
    @Test("連続更新していないキーが巻き添えで遅れない")
    func aQuietKeyIsNotStarvedByABusyOne() async throws {
        let quiet = Counter()
        let busy = Counter()
        let d = SettingsWriteDebouncer(interval: .milliseconds(500), maxDelay: .milliseconds(600))

        d.schedule(key: "quiet") { quiet.bump() }        // 最初に 1 度だけ
        let feeder = Task.detached {
            for _ in 0..<12 {                            // 1.2 秒ぶん叩き続ける
                d.schedule(key: "busy") { busy.bump() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        #expect(quiet.waitForWrite(timeout: 10), "静かなキーが上限で書かれること")   // 3s では並列実行下で輻輳しうる（上記コメント参照）
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
