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

    public init(interval: Duration = .milliseconds(500)) {
        self.interval = interval
    }

    deinit { flush() }

    /// 保留中のキー（テストと診断用）。
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

    /// 保留中の書き込みを**すべて即座に**実行する。
    public func flush() {
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
