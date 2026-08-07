// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer

/// per-library で同時 1 本のメンテナンスジョブを管理する actor のテスト（G12b-3b）。
@Suite("MaintenanceJobRegistry", .serialized)
struct MaintenanceJobRegistryTests {
    /// 同一 library で実行中に 2 本目の start を呼ぶと busy(false) になる。
    @Test func secondStartWhileRunningIsRejected() async throws {
        let reg = MaintenanceJobRegistry(onProgress: { _, _, _, _ in }, onFinished: { _, _, _, _ in })
        let gate = AsyncGate()
        let first = await reg.start(library: "L", job: "a") { _, _ in await gate.wait(); return 1 }
        #expect(first == true)
        let second = await reg.start(library: "L", job: "a") { _, _ in 0 }
        #expect(second == false)     // busy
        await gate.open()
        try await Task.sleep(for: .milliseconds(50))
    }

    /// cancel(library:) を呼ぶと isCancelled() が true を返すようになり、
    /// 完了時の onFinished outcome が "cancelled" になる。
    @Test func cancelStopsAndReportsCancelled() async throws {
        nonisolated(unsafe) var finishedOutcome = ""
        let reg = MaintenanceJobRegistry(
            onProgress: { _, _, _, _ in },
            onFinished: { _, _, outcome, _ in finishedOutcome = outcome }
        )
        _ = await reg.start(library: "L", job: "a") { _, isCancelled in
            while !(await isCancelled()) { try? await Task.sleep(for: .milliseconds(5)) }
            return 7
        }
        await reg.cancel(library: "L")
        try await Task.sleep(for: .milliseconds(80))
        #expect(finishedOutcome == "cancelled")
    }

    /// G27b Codex 2nd review Fix4: superseded run（既に終わった/取り消された古い実行）が
    /// 捕捉していた `progress` クロージャが遅れて発火しても、もう current ではない実行の
    /// SSE を出してはいけない。`status` スナップショットは既にトークンガードされていたが、
    /// `onProgress` コールバック自体はガード外にあり、修正前ならここで "A" の進捗が
    /// `onProgress` に届いてしまっていた。
    @Test func supersededRunsStaleProgressCallbackDoesNotFire() async throws {
        final class ProgressBox: @unchecked Sendable {
            var captured: (@Sendable (Int, Int) -> Void)?
        }
        // NSLock.lock()/unlock() は async コンテキストから直接呼べない（Swift 6 の
        // noasync 指定）ため、記録用の可変状態は専用クラスへ隔離し `withLock` 経由で守る
        // （`GrantRepository` と同じ流儀）。
        final class ProgressRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var calls: [(job: String, done: Int, total: Int)] = []
            func record(_ job: String, _ done: Int, _ total: Int) {
                lock.withLock { calls.append((job, done, total)) }
            }
            var snapshot: [(job: String, done: Int, total: Int)] { lock.withLock { calls } }
        }
        let box = ProgressBox()
        let recorder = ProgressRecorder()
        let reg = MaintenanceJobRegistry(
            onProgress: { _, job, done, total in recorder.record(job, done, total) },
            onFinished: { _, _, _, _ in }
        )

        // Run "A": 自分の progress クロージャを外部 box へ逃がしてから、すぐに終了する。
        let startedA = await reg.start(library: "L", job: "A") { progress, _ in
            box.captured = progress
            return 1
        }
        #expect(startedA == true)
        // A が完全に finish() し終わる（running/activeRun が消える）まで待つ ―― これで
        // 次の start("B") が確実に「新しい実行」として受理される状態になる。
        try await waitForMaintenanceJobToFinish(registry: reg, library: "L")

        // Run "B": 同じ library に新しい実行を起動する（別トークンが発行される）。
        let gate = AsyncGate()
        let startedB = await reg.start(library: "L", job: "B") { _, _ in await gate.wait(); return 2 }
        #expect(startedB == true)

        // A の古い progress クロージャを、B が起動した「後」に呼ぶ ―― これが「superseded な
        // 実行の progress が遅れて actor に届く」状況の再現（本来は fire-and-forget Task 経由の
        // 遅延で自然に起きるが、テストでは確定的に順序付ける）。
        box.captured?(99, 99)
        try await Task.sleep(for: .milliseconds(50))

        let calls = recorder.snapshot
        #expect(calls.allSatisfy { $0.job != "A" },
                "superseded run(A) の進捗コールバックが発火してしまっている: \(calls)")

        await gate.open()
        try await waitForMaintenanceJobToFinish(registry: reg, library: "L")
    }

    /// run が throw すると onFinished outcome は "failed"（Codex review Important #4）。
    /// (try? …) ?? 0 で握りつぶすと常に "done" になっていた不具合の回帰テスト。
    @Test func throwingRunReportsFailed() async throws {
        struct Boom: Error {}
        nonisolated(unsafe) var finishedOutcome = ""
        let reg = MaintenanceJobRegistry(
            onProgress: { _, _, _, _ in },
            onFinished: { _, _, outcome, _ in finishedOutcome = outcome }
        )
        _ = await reg.start(library: "L", job: "a") { _, _ in throw Boom() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(finishedOutcome == "failed")
    }
}

/// テスト補助: 手動開閉ゲート。
actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
