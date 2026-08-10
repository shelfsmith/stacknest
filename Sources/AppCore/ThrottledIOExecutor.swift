// SPDX-License-Identifier: MIT
import Foundation
import OSLog
import Darwin

/// ブロックする I/O 処理を、**低優先度かつカーネルの I/O スロットリング下**で実行するための実行器（G34a）。
///
/// ## なぜ要るのか（実測に基づく）
///
/// 2026-08-10 に稼働中の StackNest を `sample` で採取したところ、31 時間規模のフルスキャンが
/// **`PRI=46`（Finder / Safari のメインスレッドと同じ優先度）**で走っていた。
/// `MaintenanceJobRegistry.start` の非構造 `Task { }` が呼び出し元（`@MainActor` の GUI）の
/// 優先度を継承するためで、QoS が高いと macOS は I/O スロットリングを一切適用しない。
///
/// 走査スレッドは時間の 70% を `read()` syscall に費やす完全な I/O 律速であり、
/// **UI が読むもの（本体アーカイブ・サムネイル・SQLite）が全部同じディスクイメージ上にある**ため、
/// UI の小さなランダム read が走査のストリーム read の後ろに並んでいた。
/// 母艦全体は重くならないのに**アプリだけがもっさりする**のはこのため。
///
/// ## ★ なぜ `DispatchQueue` ではなく専用 `Thread` なのか（実測）
///
/// `setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, ...)` は
/// **libdispatch のワーカースレッド上では `EINVAL`(22) で失敗する** ―― QoS を dispatch が
/// 管理しているスレッドに対してカーネルが per-thread の I/O ポリシー設定を拒否する。
/// 2026-08-10 の実測:
///
/// ```
/// dispatch-utility   : rc=-1 errno=22 after=0   ← 効かない
/// dispatch-default   : rc=-1 errno=22 after=0   ← 効かない
/// raw-thread-default : rc=0  errno=0  after=3   ← 効く
/// raw-thread-utility : rc=0  errno=0  after=3   ← 効く
/// ```
///
/// **この事実は最初 `DispatchQueue` 実装で書いて、テストが `policyInside == 0` を検出したことで
/// 判明した。**「設定したから効いているはず」で通していたら、走査は throttle されないまま
/// 「対処済み」として出荷されていた。
///
/// なお `setiopolicy_np` の戻り値は**握り潰さない**。効いたかどうかは `isThrottleActive` で
/// 実際に読み戻して確かめられる（このプロジェクトが繰り返し踏んできた
/// 「確認できないことを、確認できた結果と同じ形にしてしまう」誤りを避けるため）。
public final class ThrottledIOExecutor: @unchecked Sendable {
    /// `<sys/resource.h>` の `IOPOL_THROTTLE`。最も強い後回し指定（Spotlight / Time Machine 相当）。
    /// 競合する I/O があるときカーネルが意図的に遅延を挟む＝まさに今回欲しい挙動。
    /// 走査が遅くなりすぎる場合の緩和先は `IOPOL_UTILITY`。
    public static let defaultPolicy: Int32 = IOPOL_THROTTLE

    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "ThrottledIOExecutor")

    private typealias WorkItem = @Sendable () -> Void

    private let lock = NSCondition()
    private var pending: [WorkItem] = []
    private var isStopped = false
    private var didStartThread = false
    /// スレッド上で `setiopolicy_np` を実際に適用して読み戻した結果。未起動なら nil。
    private var observedPolicy: Int32?

    private let policy: Int32
    private let label: String
    private let qualityOfService: QualityOfService

    public init(label: String = "app.shelfsmith.stacknest.throttled-io",
                policy: Int32 = ThrottledIOExecutor.defaultPolicy,
                qualityOfService: QualityOfService = .utility) {
        self.label = label
        self.policy = policy
        self.qualityOfService = qualityOfService
    }

    deinit {
        lock.lock()
        isStopped = true
        lock.broadcast()
        lock.unlock()
    }

    /// `body` を実行器の専用スレッド上で実行し、結果を返す。`body` が throw したら同じエラーを伝播する。
    ///
    /// `body` は**同期的にブロックしてよい**（むしろそれが前提）。呼び出し側の async コンテキストは
    /// continuation で待つだけなので、協調スレッドプールのスレッドは解放される。
    public func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            enqueue {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// スレッド上で I/O スロットルが**実際に有効になっているか**を返す。
    /// 一度でも `run` を通したあとに意味を持つ（それまでスレッドは起動していない）。
    /// `nil` は「まだ起動していないので分からない」であって「有効」でも「無効」でもない。
    public var isThrottleActive: Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let observedPolicy else { return nil }
        return observedPolicy == policy
    }

    /// 現在のスレッドのディスク I/O ポリシーを返す（テストと診断用）。
    public static func currentThreadDiskPolicy() -> Int32 {
        getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
    }

    // MARK: - 内部

    private func enqueue(_ item: @escaping WorkItem) {
        lock.lock()
        pending.append(item)
        if !didStartThread {
            didStartThread = true
            startThread()
        }
        lock.signal()
        lock.unlock()
    }

    /// **`lock` を保持した状態で呼ぶこと。**
    private func startThread() {
        let thread = Thread { [weak self] in
            // ★ 生の Thread 上でのみ成功する（dispatch worker では EINVAL）。冒頭のコメント参照。
            _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, self?.policy ?? IOPOL_THROTTLE)
            // 設定できたことを**読み戻して**記録する。効かなかった場合に「効いたつもり」で
            // 走らせないため、成功の可否は推測せず観測値で持つ。
            let observed = Self.currentThreadDiskPolicy()
            let requested = self?.policy ?? IOPOL_THROTTLE
            // 実機で「本当に効いたか」を外から確かめられるようにする。
            // 単体テストは通っても、実行環境が変われば同じ設定が拒否されうる
            // （dispatch worker では EINVAL になることが実測で分かっている）。
            // `log show --predicate 'category == "ThrottledIOExecutor"'` で確認できる。
            if observed == requested {
                Self.logger.info("disk I/O throttle active (policy=\(observed, privacy: .public))")
            } else {
                Self.logger.error(
                    "disk I/O throttle NOT applied (requested=\(requested, privacy: .public) observed=\(observed, privacy: .public)) — scan will compete with UI I/O")
            }
            self?.threadLoop(observedPolicy: observed)
        }
        thread.name = label
        thread.qualityOfService = qualityOfService
        thread.start()
    }

    private func threadLoop(observedPolicy: Int32) {
        lock.lock()
        self.observedPolicy = observedPolicy
        while true {
            while pending.isEmpty && !isStopped {
                lock.wait()
            }
            if isStopped && pending.isEmpty {
                lock.unlock()
                return
            }
            let item = pending.removeFirst()
            lock.unlock()
            item()
            lock.lock()
        }
    }
}
