// SPDX-License-Identifier: MIT
import Foundation

/// per-library で同時 1 本のメンテナンスジョブを管理する actor。
///
/// - `start` は同一 library で既に実行中のジョブがあれば起動せず false（busy）を返す。
/// - `run` クロージャに渡す `isCancelled` は actor 隔離状態を読むため async。
///   コア（`fillMissingSeriesVolume`/`compressOversizedCovers`）の `isCancelled` 引数と
///   シグネチャを揃えている（`() async -> Bool`）。
/// - 進捗・完了は `onProgress`/`onFinished` コールバック経由でサーバ（Task 7）に通知し、SSE へ転送する。
/// - G27b: 直近の進捗（job 名・done/total・開始時刻）を `statuses` に保持し、`status(library:)` で
///   同期的に問い合わせられる。31 時間規模のフルスキャンを SSE を張り続けずに確認するため。
///   `emitProgress` は `running.contains(l)` を見てから書き込む — `progress(...)` は不構造 Task
///   経由で actor に届くため、run 完了直後の最後の progress 呼び出しが finish() より後にこの
///   actor 上で実行されることがあり、ガード無しでは既に終わった job の幽霊状態が statuses に
///   復活してしまう（実テストで踏んだ実例）。
public actor MaintenanceJobRegistry {
    /// `status(library:)` が返す進捗スナップショット。
    public struct JobStatus: Sendable, Equatable {
        public var job: String
        public var done: Int
        public var total: Int
        public var startedAt: Date
    }

    private var running: Set<String> = []
    private var cancelledLibs: Set<String> = []
    /// G27b: library ごとの最新進捗。`running` に居る間だけ値を持つ（完了/失敗/中断で必ず消す）。
    private var statuses: [String: JobStatus] = [:]
    private let onProgress: @Sendable (String, String, Int, Int) -> Void
    private let onFinished: @Sendable (String, String, String, Int) -> Void
    /// G27b: 開始時刻の取得元。テストから固定時刻を注入できるよう既定は `Date.init` を渡す。
    private let now: @Sendable () -> Date

    /// コールバックは construction 時に同期的に確定させる（Codex review Important #1）。
    /// 旧 setOnProgress/setOnFinished（async setter）は起動直後の Task 内で配線していたため、
    /// registry 構築〜配線 Task 実行までの間に完了したジョブの通知が失われるレースがあった。
    /// `statuses` の書き込みも同じ理由で `start` 内で Task 起動前に同期的に行う（下記参照）。
    public init(
        onProgress: @escaping @Sendable (String, String, Int, Int) -> Void,
        onFinished: @escaping @Sendable (String, String, String, Int) -> Void,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.onProgress = onProgress
        self.onFinished = onFinished
        self.now = now
    }

    private func isCancelledLib(_ library: String) -> Bool { cancelledLibs.contains(library) }
    private func emitProgress(_ l: String, _ j: String, _ d: Int, _ t: Int) {
        // progress は `Task { await self.emitProgress(...) }` という不構造 Task 経由で actor に届く
        // ため、run 完了直後の最後の progress(...) 呼び出しが finish() より後にこの actor 上で
        // 実行されることがある（run 自身は progress を待たずに return できるため）。ここで
        // running.contains(l) を見ずに書き込むと、既に finish 済みの library に幽霊の
        // running 状態が復活してしまう（statuses に残る）。running から外れていたら
        // 保持はスキップする — SSE への onProgress 転送（既存挙動）はガードせず必ず通す。
        if running.contains(l) {
            let startedAt = statuses[l]?.startedAt ?? now()
            statuses[l] = JobStatus(job: j, done: d, total: t, startedAt: startedAt)
        }
        onProgress(l, j, d, t)
    }
    private func finish(_ l: String, _ j: String, _ count: Int, failed: Bool) {
        let outcome = failed ? "failed" : (cancelledLibs.contains(l) ? "cancelled" : "done")
        running.remove(l); cancelledLibs.remove(l); statuses[l] = nil
        onFinished(l, j, outcome, count)
    }

    /// 起動できたら true。既に同 library で実行中なら false（busy）。
    /// run が throw した場合は outcome "failed" として通知する（Codex review Important #4）。
    @discardableResult
    public func start(
        library: String, job: String,
        run: @escaping @Sendable (_ progress: @Sendable (Int, Int) -> Void, _ isCancelled: @Sendable () async -> Bool) async throws -> Int
    ) -> Bool {
        guard !running.contains(library) else { return false }
        running.insert(library); cancelledLibs.remove(library)
        // status(library:) が start() 直後から running:true を返せるよう、Task 起動前に
        // 同期的に確定させる（コールバックを init で固定した理由と同じレース回避。上記コメント参照）。
        statuses[library] = JobStatus(job: job, done: 0, total: 0, startedAt: now())
        Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (Int, Int) -> Void = { done, total in
                Task { await self.emitProgress(library, job, done, total) }
            }
            let isCancelled: @Sendable () async -> Bool = { await self.isCancelledLib(library) }
            do {
                let count = try await run(progress, isCancelled)
                await self.finish(library, job, count, failed: false)
            } catch {
                await self.finish(library, job, 0, failed: true)
            }
        }
        return true
    }

    public func cancel(library: String) { if running.contains(library) { cancelledLibs.insert(library) } }

    /// G27b: library の現在のジョブ状態を返す。実行中でなければ nil。
    public func status(library: String) -> JobStatus? { statuses[library] }
}
