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
public enum ThrottledIOExecutorError: Error, Equatable {
    /// 実行器が既に停止している（解放後）。新しい仕事は受け付けられない。
    case stopped
}

public final class ThrottledIOExecutor: @unchecked Sendable {
    /// `<sys/resource.h>` の `IOPOL_THROTTLE`。最も強い後回し指定（Spotlight / Time Machine 相当）。
    /// 競合する I/O があるときカーネルが意図的に遅延を挟む＝まさに今回欲しい挙動。
    /// 走査が遅くなりすぎる場合の緩和先は `IOPOL_UTILITY`。
    public static let defaultPolicy: Int32 = IOPOL_THROTTLE

    /// 走査の I/O ポリシーを UserDefaults から上書きする（診断・調整用）。
    ///
    /// ```sh
    /// defaults write app.shelfsmith.stacknest stacknest.scanIOPolicy utility   # 緩める
    /// defaults write app.shelfsmith.stacknest stacknest.scanIOPolicy standard  # 実質無効（比較測定用）
    /// defaults delete app.shelfsmith.stacknest stacknest.scanIOPolicy          # 既定へ戻す
    /// ```
    ///
    /// 用途は 2 つ。①**同一の本集合で throttle 有無を A/B 測定する**（そうしないと
    /// 「遅くなった分がスロットルのせいなのか、対象の本が違うだけなのか」を切り分けられない）。
    /// ②体感と走査時間のトレードオフを、再ビルドせずに調整できるようにする。
    /// 不明な値は既定（`throttle`）として扱う ―― 打ち間違いで**無効化されて**しまい、
    /// 「効いているつもり」で走るのを避けるため。効いたかどうかは `isThrottleActive` で読める。
    public static func configuredPolicy(
        _ defaults: UserDefaults = .standard,
        key: String = "stacknest.scanIOPolicy"
    ) -> Int32 {
        // `important`(1) は受け付けない。設定しても `getiopolicy_np` は 0（default）を返すため
        // **適用できたかを読み戻して確かめられない**（実測）。検証できない選択肢を残すと
        // 「効いているつもり」の余地になるので、そもそも選ばせない。
        switch defaults.string(forKey: key)?.lowercased() {
        case "utility":  return IOPOL_UTILITY
        case "standard": return IOPOL_STANDARD
        default:         return defaultPolicy
        }
    }

    static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "ThrottledIOExecutor")

    /// ★ ワーカーを別オブジェクトに分けている理由（Codex レビュー P2）。
    ///
    /// 初版はスレッドのクロージャが `self?.threadLoop()` を呼んでおり、**呼び出しの間ずっと
    /// executor を強参照していた**。`threadLoop` は `isStopped` が立つまで返らず、`isStopped` は
    /// `deinit` でしか立たない ―― つまり「スレッドが executor を生かし、executor の死だけが
    /// スレッドを止める」という所有の循環になっていて、`deinit` は永久に走らなかった。
    /// 走査のたびに `liveDependencies` が executor を 1 個作るので、**ネイティブスレッドが
    /// 1 本ずつ漏れ続ける**。
    ///
    /// スレッドが持つのはこの `Worker`（キューと停止フラグだけの小さな箱）にして、
    /// executor の `deinit` が `Worker.stop()` を呼ぶ。executor は誰からも参照されなくなれば
    /// 解放され、ワーカーは残った仕事を捌いてからスレッドを終える。
    final class Worker: @unchecked Sendable {
        typealias WorkItem = @Sendable () -> Void

        private let lock = NSCondition()
        private var pending: [WorkItem] = []
        private var isStopped = false
        private var didStartThread = false
        /// スレッド上で `setiopolicy_np` を実際に適用して読み戻した結果。未起動なら nil。
        private var observedPolicy: Int32?
        /// スレッドがループを抜けたか（終了できたことをテストから観測するため）。
        private var didExit = false

        let policy: Int32
        private let label: String
        private let qualityOfService: QualityOfService

        init(label: String, policy: Int32, qualityOfService: QualityOfService) {
            self.label = label
            self.policy = policy
            self.qualityOfService = qualityOfService
        }

        /// 以後の新規受付をやめ、残った仕事を捌いてからスレッドを終わらせる。
        /// **積まれた仕事は捨てない** ―― `run` の continuation が resume されないまま
        /// 捨てられると、`withCheckedContinuation` がリークとして落ちる。
        func stop() {
            lock.lock()
            isStopped = true
            lock.broadcast()
            lock.unlock()
        }

        /// 仕事を積む。**停止済みなら受け付けず `false` を返す。**
        ///
        /// ★ 黙って積んではいけない。スレッドは既に抜けており、`didStartThread` が立っているため
        /// 新しいスレッドも起動しない ―― 積んだ仕事は永久に実行されず、`run` の continuation が
        /// resume されないまま宙に浮く（＝呼び出し側が無期限にハングする）。
        /// 実際にこの実装の初版でテストがハングして発覚した。
        /// 受け付けられないことを呼び出し側へ返し、`run` はエラーとして解決させる。
        func enqueue(_ item: @escaping WorkItem) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isStopped else { return false }
            pending.append(item)
            if !didStartThread {
                didStartThread = true
                startThread()
            }
            lock.signal()
            return true
        }

        var throttleState: (observed: Int32?, requested: Int32) {
            lock.lock()
            defer { lock.unlock() }
            return (observedPolicy, policy)
        }

        /// テスト用: スレッドが実際に終了したか。
        var hasExited: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didExit
        }

        /// **`lock` を保持した状態で呼ぶこと。**
        private func startThread() {
            // ここで `self`（Worker）を強参照するのは意図どおり。Worker は小さく、
            // `stop()` を受ければ確実に抜ける（上のコメント参照）。
            let thread = Thread { [self] in
                // ★ 生の Thread 上でのみ成功する（dispatch worker では EINVAL）。冒頭のコメント参照。
                _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, policy)
                // 設定できたことを**読み戻して**記録する。効かなかった場合に「効いたつもり」で
                // 走らせないため、成功の可否は推測せず観測値で持つ。
                let observed = ThrottledIOExecutor.currentThreadDiskPolicy()
                // 実機で「本当に効いたか」を外から確かめられるようにする。
                // 単体テストは通っても、実行環境が変われば同じ設定が拒否されうる
                // （dispatch worker では EINVAL になることが実測で分かっている）。
                // `log show --predicate 'category == "ThrottledIOExecutor"'` で確認できる。
                if observed == policy {
                    // 既定以外（測定・調整で `standard` 等にした場合）に "throttle active" と出ると
                    // 誤読するので、要求どおりに適用できたことと実際の値を分けて書く。
                    // 判定は `isThrottleActive` と同じ述語を共有する（二重定義にしない）。
                    let throttled = ThrottledIOExecutor.isThrottlingPolicy(observed)
                    ThrottledIOExecutor.logger.info(
                        "disk I/O policy applied: \(observed, privacy: .public) (throttled=\(throttled, privacy: .public))")
                } else {
                    let requested = self.policy
                    ThrottledIOExecutor.logger.error(
                        "disk I/O throttle NOT applied (requested=\(requested, privacy: .public) observed=\(observed, privacy: .public)) — scan will compete with UI I/O")
                }
                threadLoop(observedPolicy: observed)
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
                if pending.isEmpty && isStopped {
                    didExit = true
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

    let worker: Worker

    public init(label: String = "app.shelfsmith.stacknest.throttled-io",
                policy: Int32 = ThrottledIOExecutor.defaultPolicy,
                qualityOfService: QualityOfService = .utility) {
        self.worker = Worker(label: label, policy: policy, qualityOfService: qualityOfService)
    }

    deinit {
        worker.stop()
    }

    /// `body` を実行器の専用スレッド上で実行し、結果を返す。`body` が throw したら同じエラーを伝播する。
    ///
    /// `body` は**同期的にブロックしてよい**（むしろそれが前提）。呼び出し側の async コンテキストは
    /// continuation で待つだけなので、協調スレッドプールのスレッドは解放される。
    public func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let accepted = worker.enqueue {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            // 受け付けられなかった（＝停止済み）なら**必ずここで解決する**。
            // resume せずに戻ると呼び出し側が無期限に待ち続ける。
            if !accepted { continuation.resume(throwing: ThrottledIOExecutorError.stopped) }
        }
    }

    /// そのポリシー値が「後回しにする」種類かどうか。
    ///
    /// `IOPOL_STANDARD` / `IOPOL_IMPORTANT` は**スロットルしない**指定である。
    /// この判定はログと `isThrottleActive` の両方が使う ―― 別々に書くと、
    /// 「ログは throttled=false と言っているのにプロパティは true を返す」という
    /// 食い違いが起きる（Codex レビュー P2 で実際に指摘された）。
    static func isThrottlingPolicy(_ policy: Int32) -> Bool {
        policy != IOPOL_STANDARD && policy != IOPOL_IMPORTANT
    }

    /// スレッド上で I/O スロットルが**実際に有効になっているか**を返す。
    /// 一度でも `run` を通したあとに意味を持つ（それまでスレッドは起動していない）。
    ///
    /// - `nil`: まだスレッドが起動していないので**分からない**（「有効」でも「無効」でもない）
    /// - `false`: 要求したポリシーを適用できなかった、**または**適用できたがそれが
    ///   スロットルしない種類（`standard` / `important` ＝ A/B 測定で意図的に切っている状態）
    /// - `true`: 後回し指定が実際に効いている
    ///
    /// **「要求どおり適用できたか」と「スロットルが効いているか」は別の問い。**
    /// このプロパティは名前どおり後者だけを答える。
    public var isThrottleActive: Bool? {
        let state = worker.throttleState
        guard let observed = state.observed else { return nil }
        guard observed == state.requested else { return false }
        return Self.isThrottlingPolicy(observed)
    }

    /// 現在のスレッドのディスク I/O ポリシーを返す（テストと診断用）。
    public static func currentThreadDiskPolicy() -> Int32 {
        getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
    }

}
