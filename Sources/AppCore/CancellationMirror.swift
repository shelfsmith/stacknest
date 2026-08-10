// SPDX-License-Identifier: MIT
import Foundation

/// 非同期の中断問い合わせを、**同期的に読めるフラグ**へ一定間隔で写す（G34a）。
///
/// ## なぜ要るのか
///
/// 走査の CRC 検証は `ThrottledIOExecutor` の専用スレッド上を**同期的に**走る
/// （`setiopolicy_np` がスレッド単位の設定であるため、同期ループであることが前提）。
/// 一方、中断状態を持つのは `MaintenanceJobRegistry`＝**actor** で、問い合わせは async である。
/// 同期ループから actor は待てないので、間に非同期のポーラを挟んでフラグへ写す。
///
/// ## 粒度について
///
/// 従来は**アーカイブ 1 エントリごと**に actor へホップして中断を確認していた。
/// 既定の 0.5 秒間隔はそれより粗いが、**1 冊あたり約 1.6 秒**（実測）に対しては十分細かい。
/// 元の設計意図は「冊単位（数秒〜）では 31 時間規模の走査を打ち切るのに粗すぎる」であり、
/// 0.5 秒はそれを満たす。副次的に、1 冊で数百回発生していた actor ホップも無くなる。
public final class CancellationMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    public init(initialValue: Bool = false) {
        self.value = initialValue
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

extension CancellationMirror {
    /// `probe`（async）の結果を `interval` 間隔でミラーへ写しながら `body` を実行する。
    /// `body` には**同期的に読める中断判定**が渡される。
    ///
    /// **★ `body` を始める前に `probe` を 1 回必ず評価する。** ポーラの最初の起床は `interval`
    /// 後なので、これが無いと「開始時点で既に中断されている」を取りこぼす ―― 走査は 1 冊ごとに
    /// この関数を通るため、取りこぼすと中断してから止まるまでに残り全冊を読み切ってしまう。
    ///
    /// ポーラは `body` の完走・throw いずれでも必ず停止する（`defer`）。1 冊ごとに Task が
    /// 漏れると数万冊の走査で破綻する。
    public static func mirroring<T: Sendable>(
        probe: @escaping @Sendable () async -> Bool,
        interval: Duration = .milliseconds(500),
        body: (_ isCancelled: @escaping @Sendable () -> Bool) async throws -> T
    ) async rethrows -> T {
        let mirror = CancellationMirror(initialValue: await probe())
        let poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                mirror.set(await probe())
            }
        }
        defer { poller.cancel() }
        return try await body({ mirror.isCancelled })
    }
}
