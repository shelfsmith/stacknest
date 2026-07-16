// SPDX-License-Identifier: MIT
import Foundation

/// per-library で同時 1 本のメンテナンスジョブを管理する actor。
///
/// - `start` は同一 library で既に実行中のジョブがあれば起動せず false（busy）を返す。
/// - `run` クロージャに渡す `isCancelled` は actor 隔離状態を読むため async。
///   コア（`fillMissingSeriesVolume`/`compressOversizedCovers`）の `isCancelled` 引数と
///   シグネチャを揃えている（`() async -> Bool`）。
/// - 進捗・完了は `onProgress`/`onFinished` コールバック経由でサーバ（Task 7）に通知し、SSE へ転送する。
public actor MaintenanceJobRegistry {
    private var running: Set<String> = []
    private var cancelledLibs: Set<String> = []
    private let onProgress: @Sendable (String, String, Int, Int) -> Void
    private let onFinished: @Sendable (String, String, String, Int) -> Void

    /// コールバックは construction 時に同期的に確定させる（Codex review Important #1）。
    /// 旧 setOnProgress/setOnFinished（async setter）は起動直後の Task 内で配線していたため、
    /// registry 構築〜配線 Task 実行までの間に完了したジョブの通知が失われるレースがあった。
    public init(
        onProgress: @escaping @Sendable (String, String, Int, Int) -> Void,
        onFinished: @escaping @Sendable (String, String, String, Int) -> Void
    ) {
        self.onProgress = onProgress
        self.onFinished = onFinished
    }

    private func isCancelledLib(_ library: String) -> Bool { cancelledLibs.contains(library) }
    private func emitProgress(_ l: String, _ j: String, _ d: Int, _ t: Int) { onProgress(l, j, d, t) }
    private func finish(_ l: String, _ j: String, _ count: Int, failed: Bool) {
        let outcome = failed ? "failed" : (cancelledLibs.contains(l) ? "cancelled" : "done")
        running.remove(l); cancelledLibs.remove(l)
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
}
