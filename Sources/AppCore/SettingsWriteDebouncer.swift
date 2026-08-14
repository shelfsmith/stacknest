// SPDX-License-Identifier: MIT
import Foundation

/// 連続する設定の永続化をまとめて 1 回にする（G36 ③）。
///
/// ## なぜ要るか（実測）
///
/// `LibrarySettings` の `didSet { persist* }` は 30 個あり、すべて同期的に
/// `setLibrarySetting` → **commit + fsync** を呼ぶ。ライブラリは USB HDD 上の
/// 暗号化ディスクイメージにあり **1 操作 36〜80ms**。
///
/// そのうち 3 つは**ドラッグ中ずっと発火する**:
/// - `columnWidths` … `NSTableView.columnDidResizeNotification`（列ドラッグ中）
/// - `gridItemSize` … `Slider` に直結
/// - `windowFrame` … `NSWindow.didResize` / `didMove`
///
/// 1 ドラッグが数十〜数百回の fsync になっていた。
///
/// ## 何を遅らせるのか
///
/// **ディスクへの書き込みだけ。** メモリ上の値は `didSet` で即時更新されるので、
/// **UI の見た目は一切変わらない**。
///
/// ## ★ flush の責任
///
/// 遅延書き込みを入れる以上、「書かれないまま終わる」経路を塞ぐのは**呼び出し側の責任**。
/// アプリ終了時とライブラリを閉じるときに必ず `flush()` すること
/// （ウィンドウ位置や列幅が保存されない退行は、すぐ気づかれる類の欠陥になる）。
public final class SettingsWriteDebouncer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: @Sendable () -> Void] = [:]
    private var timer: DispatchSourceTimer?
    private let interval: Duration
    private let queue = DispatchQueue(label: "app.shelfsmith.stacknest.settings-debounce")
    /// 現在の実行が `queue` 上かどうかを判定するためのキー（`flush()` の自己デッドロック回避、G36 ③ C1）。
    private let queueKey = DispatchSpecificKey<Void>()

    public init(interval: Duration = .milliseconds(500)) {
        self.interval = interval
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { flush() }

    /// **まだ drain されていない**キーの集合（テストと診断用）。
    ///
    /// - `true`（=集合に含まれる）: そのキーの書き込みはまだタイマ待ちで、ディスクに未反映。
    /// - **`isEmpty` は「ディスクが最新である」ことを意味しない。** `flush()` は drain した
    ///   write を直列キューに乗せてから実行するため、`pendingKeys` は「実行完了」ではなく
    ///   「drain 済みかどうか」しか表さない。ある write が drain された直後・実行中の瞬間には
    ///   もう `pendingKeys` から消えているが、ディスクへの書き込みはまだ完了していない。
    ///   「すべての書き込みが確実に完了したこと」を保証したいなら、`flush()` の**呼び出しが
    ///   return したこと**を根拠にすること（`flush()` は自身が drain した write の実行完了を
    ///   待ってから return する。G36 ③ I2）。
    public var pendingKeys: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(pending.keys)
    }

    /// `key` の書き込みを予約する。**同じキーを続けて積むと最後のものだけが実行される。**
    public func schedule(key: String, write: @escaping @Sendable () -> Void) {
        lock.lock()
        pending[key] = write
        lock.unlock()
        restartTimer()
    }

    /// 保留中の書き込みを**すべて即座に**実行する。呼び出しは実行完了まで待って return する。
    ///
    /// ## なぜ直列キューを通すのか（G36 ③ C1 の修正）
    ///
    /// drain（`pending` を取り出して空にする）はロック下で原子的だが、write の**実行**まで
    /// ロックの外に出すと、2 つの `flush()` が write を並行に・任意の順序で完了できてしまう。
    /// 典型的な事故: タイマ発火の `flush()` が古い値の write を実行中（fsync で 36〜80ms）に、
    /// 別スレッドの明示的な `flush()`（アプリ終了時など）が新しい値を先に書き終え、その後で
    /// 古い write が完了して新しい値を踏み潰す。これは「同じキーは最後の書き込みだけが
    /// 実行される」という本機構の契約を破る。
    ///
    /// 対策として、drain と write の実行を**単一の直列 `queue` の 1 タスク**として扱う。
    /// 直列キューは投入順に 1 つずつしか実行しないため、後から `flush()` された分は必ず
    /// 先行する `flush()` の write が完了してから実行される＝完了順序が投入順序と一致する。
    ///
    /// タイマのハンドラは既にこの `queue` 上で動くため、素の `queue.sync` を使うと
    /// 自己デッドロックする。`DispatchSpecificKey` で「今このスレッドが `queue` 上か」を
    /// 判定し、既に `queue` 上ならロックを取らずその場で drain+execute する
    /// （`executionLock` のような追加ロックは使わない。write の中から `schedule`/`flush` が
    /// 再入しても、`queue` 上にいる限り `queue.sync` を経由しないのでデッドロックしない）。
    public func flush() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            drainAndExecute()
        } else {
            queue.sync { self.drainAndExecute() }
        }
    }

    /// `pending` を原子的に drain し、その場で write を実行する。
    /// 呼び出し元（`flush()`）が「常に `queue` 上、または `queue` 上と同期して」呼ぶことで
    /// 複数回の drain+execute が互いに直列化される。
    private func drainAndExecute() {
        lock.lock()
        let writes = Array(pending.values)
        pending.removeAll()
        timer?.cancel()
        timer = nil
        lock.unlock()
        for write in writes { write() }
    }

    private func restartTimer() {
        lock.lock()
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let ms = Int(interval.components.seconds * 1000
                     + interval.components.attoseconds / 1_000_000_000_000_000)
        t.schedule(deadline: .now() + .milliseconds(max(1, ms)))
        t.setEventHandler { [weak self] in self?.flush() }
        timer = t
        lock.unlock()
        t.resume()
    }
}
