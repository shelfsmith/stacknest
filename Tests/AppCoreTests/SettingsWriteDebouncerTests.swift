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
}
