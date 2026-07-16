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
    private var onProgress: (@Sendable (String, String, Int, Int) -> Void)?
    private var onFinished: (@Sendable (String, String, String, Int) -> Void)?

    public init() {}
    public func setOnProgress(_ cb: @escaping @Sendable (String, String, Int, Int) -> Void) { onProgress = cb }
    public func setOnFinished(_ cb: @escaping @Sendable (String, String, String, Int) -> Void) { onFinished = cb }

    private func isCancelledLib(_ library: String) -> Bool { cancelledLibs.contains(library) }
    private func emitProgress(_ l: String, _ j: String, _ d: Int, _ t: Int) { onProgress?(l, j, d, t) }
    private func finish(_ l: String, _ j: String, _ count: Int) {
        let outcome = cancelledLibs.contains(l) ? "cancelled" : "done"
        running.remove(l); cancelledLibs.remove(l)
        onFinished?(l, j, outcome, count)
    }

    /// 起動できたら true。既に同 library で実行中なら false（busy）。
    @discardableResult
    public func start(
        library: String, job: String,
        run: @escaping @Sendable (_ progress: @Sendable (Int, Int) -> Void, _ isCancelled: @Sendable () async -> Bool) async -> Int
    ) -> Bool {
        guard !running.contains(library) else { return false }
        running.insert(library); cancelledLibs.remove(library)
        Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (Int, Int) -> Void = { done, total in
                Task { await self.emitProgress(library, job, done, total) }
            }
            let isCancelled: @Sendable () async -> Bool = { await self.isCancelledLib(library) }
            let count = await run(progress, isCancelled)
            await self.finish(library, job, count)
        }
        return true
    }

    public func cancel(library: String) { if running.contains(library) { cancelledLibs.insert(library) } }
}
