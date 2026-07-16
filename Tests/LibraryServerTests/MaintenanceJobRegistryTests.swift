// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServer

/// per-library で同時 1 本のメンテナンスジョブを管理する actor のテスト（G12b-3b）。
@Suite("MaintenanceJobRegistry", .serialized)
struct MaintenanceJobRegistryTests {
    /// 同一 library で実行中に 2 本目の start を呼ぶと busy(false) になる。
    @Test func secondStartWhileRunningIsRejected() async throws {
        let reg = MaintenanceJobRegistry()
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
        let reg = MaintenanceJobRegistry()
        nonisolated(unsafe) var finishedOutcome = ""
        await reg.setOnFinished { _, _, outcome, _ in finishedOutcome = outcome }
        _ = await reg.start(library: "L", job: "a") { _, isCancelled in
            while !(await isCancelled()) { try? await Task.sleep(for: .milliseconds(5)) }
            return 7
        }
        await reg.cancel(library: "L")
        try await Task.sleep(for: .milliseconds(80))
        #expect(finishedOutcome == "cancelled")
    }
}

/// テスト補助: 手動開閉ゲート。
actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
