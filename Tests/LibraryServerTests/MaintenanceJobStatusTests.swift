// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// MaintenanceJobRegistry.status(library:) と GET .../maintenance/status のテスト（G27b）。
/// 31 時間規模のフルスキャンを SSE を張らずに問い合わせられることの確認。
/// `AsyncGate` は Tests/LibraryServerTests/MaintenanceJobRegistryTests.swift 定義のものを再利用する。
@Suite("MaintenanceJobRegistry status / GET maintenance/status (G27b)", .serialized)
struct MaintenanceJobStatusTests {

    private func makeCore(fixture: TestLibraryFixture, adminTier: Bool) -> LibraryServerCore {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: adminTier),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()])
        )
    }

    // MARK: - actor レベル

    /// 実行前は status(library:) が nil（= running:false 相当）。
    @Test func idleLibraryReportsNoStatus() async throws {
        let reg = MaintenanceJobRegistry(onProgress: { _, _, _, _ in }, onFinished: { _, _, _, _ in })
        let status = await reg.status(library: "L")
        #expect(status == nil)
    }

    /// 実行中は done/total がジョブの progress コールバックの発火に追従して進む。
    @Test func runningJobStatusAdvancesWithProgress() async throws {
        let reg = MaintenanceJobRegistry(onProgress: { _, _, _, _ in }, onFinished: { _, _, _, _ in })
        let gate1 = AsyncGate()
        let gate2 = AsyncGate()
        let started = await reg.start(library: "L", job: "scan") { progress, _ in
            progress(1, 10)
            await gate1.wait()
            progress(5, 10)
            await gate2.wait()
            return 10
        }
        #expect(started == true)

        try await Task.sleep(for: .milliseconds(50))
        let afterFirst = await reg.status(library: "L")
        #expect(afterFirst?.job == "scan")
        #expect(afterFirst?.done == 1)
        #expect(afterFirst?.total == 10)

        await gate1.open()
        try await Task.sleep(for: .milliseconds(50))
        let afterSecond = await reg.status(library: "L")
        #expect(afterSecond?.done == 5)
        #expect(afterSecond?.total == 10)
        // startedAt はジョブ開始時刻から変わらない（進捗更新のたびに動かない）。
        #expect(afterFirst?.startedAt == afterSecond?.startedAt)

        await gate2.open()
        try await Task.sleep(for: .milliseconds(50))
    }

    /// 完了後は status(library:) が再び nil に戻る。
    @Test func completedJobReturnsToIdle() async throws {
        let reg = MaintenanceJobRegistry(onProgress: { _, _, _, _ in }, onFinished: { _, _, _, _ in })
        _ = await reg.start(library: "L", job: "scan") { progress, _ in
            progress(3, 3)
            return 3
        }
        try await Task.sleep(for: .milliseconds(80))
        let status = await reg.status(library: "L")
        #expect(status == nil)
    }

    /// レビュー指摘の回帰: A 完了直後に同一 library で B が start された場合、A の
    /// 遅延 progress（finish(A) より後にこの actor 上で実行される最後の progress(...)）が
    /// statuses[l] を B から A へ**取り違えて上書き**しないこと。
    ///
    /// `Task.sleep` による祈りではなく、A の `progress` クロージャを外へ捕捉して**呼ばずに**
    /// run(A) を return させる（→ finish(A) が確実に先に完了する）→ B を start する→
    /// その後で**明示的に**捕捉した A の progress を呼んで「遅れて届いた A の通知」を再現する、
    /// という順序を onFinished/onProgress コールバック駆動の AsyncGate で強制する。
    @Test func staleProgressFromFinishedJobDoesNotOverwriteNewerJob() async throws {
        nonisolated(unsafe) var capturedProgressA: (@Sendable (Int, Int) -> Void)?
        let aFinished = AsyncGate()
        let lateProgressDelivered = AsyncGate()

        let reg = MaintenanceJobRegistry(
            onProgress: { l, j, d, t in
                if l == "L", j == "A", d == 3, t == 3 {
                    Task { await lateProgressDelivered.open() }
                }
            },
            onFinished: { l, j, _, _ in
                if l == "L", j == "A" {
                    Task { await aFinished.open() }
                }
            }
        )

        // ジョブ A: progress は「呼ばずに」参照だけ外へ捕捉し、即 return する
        // （= すぐ finish(A) が走る。まだ捕捉した progress は一度も呼んでいない）。
        let startedA = await reg.start(library: "L", job: "A") { progress, _ in
            capturedProgressA = progress
            return 1
        }
        #expect(startedA == true)
        // onFinished(A) の発火を待つ = finish(A) 完了（running/statuses から A が消えたこと）を
        // 確定させる。同じ Task 内で capturedProgressA の代入 → run 完了 → finish の順に
        // 実行されるため、ここまで来れば代入は必ず完了している。
        await aFinished.wait()
        let progressA = try #require(capturedProgressA)
        let idleAfterAFinished = await reg.status(library: "L")
        #expect(idleAfterAFinished == nil)

        // ジョブ B を同一 library で start する（A は finish 済みなので busy にならない）。
        let bGate = AsyncGate()
        let startedB = await reg.start(library: "L", job: "B") { _, _ in
            await bGate.wait()
            return 5
        }
        #expect(startedB == true)
        let statusAfterBStart = await reg.status(library: "L")
        #expect(statusAfterBStart?.job == "B")

        // ここで「保留していた A の遅延 progress」を明示的に解放する（finish(A) 後・B 実行中）。
        // ジョブ単位でガードしていなければ、この呼び出しが statuses["L"] を
        // job:"A", done:3, total:3 へ取り違えて上書きしてしまう。
        progressA(3, 3)
        await lateProgressDelivered.wait()

        let statusAfterLateProgress = await reg.status(library: "L")
        #expect(statusAfterLateProgress?.job == "B")
        #expect(statusAfterLateProgress?.done == 0)
        #expect(statusAfterLateProgress?.total == 0)

        await bGate.open()
        try await Task.sleep(for: .milliseconds(50))
    }

    /// 回帰: 実行中に 2 本目の start を呼ぶと引き続き busy(false)。既存の SSE
    /// progress/finished コールバックも status 追跡の追加後に変わらず発火する
    /// （complete-metadata / compress-covers が依存している契約）。
    @Test func secondStartWhileRunningStaysRejectedAndCallbacksStillFire() async throws {
        nonisolated(unsafe) var progressCalls: [(String, String, Int, Int)] = []
        nonisolated(unsafe) var finishedOutcome = ""
        let reg = MaintenanceJobRegistry(
            onProgress: { l, j, d, t in progressCalls.append((l, j, d, t)) },
            onFinished: { _, _, outcome, _ in finishedOutcome = outcome }
        )
        let gate = AsyncGate()
        let first = await reg.start(library: "L", job: "a") { progress, _ in
            progress(1, 2)
            await gate.wait()
            return 2
        }
        #expect(first == true)
        let second = await reg.start(library: "L", job: "a") { _, _ in 0 }
        #expect(second == false) // busy（既存挙動の回帰）

        try await Task.sleep(for: .milliseconds(50))
        #expect(progressCalls.contains { $0.0 == "L" && $0.1 == "a" && $0.2 == 1 && $0.3 == 2 })

        await gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(finishedOutcome == "done")
    }

    /// startedAt はコンストラクタに注入した clock から取られる（wall time 非依存でテストできる）。
    @Test func startedAtUsesInjectedClock() async throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let reg = MaintenanceJobRegistry(
            onProgress: { _, _, _, _ in }, onFinished: { _, _, _, _ in }, now: { fixed }
        )
        let gate = AsyncGate()
        _ = await reg.start(library: "L", job: "a") { _, _ in await gate.wait(); return 1 }
        let status = await reg.status(library: "L")
        #expect(status?.startedAt == fixed)
        await gate.open()
        try await Task.sleep(for: .milliseconds(30))
    }

    // MARK: - エンドポイント（GET .../maintenance/status）

    /// GET .../maintenance/status: edit トークンは 403（隣接 maintenance ルートと同じ admin 権限）。
    @Test func statusEndpointRequiresAdmin() async throws {
        let fx = try TestLibraryFixture(name: "MSEdit", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let core = makeCore(fixture: fx, adminTier: false)
        try await core.buildApplication().test(.router) { client in
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/maintenance/status",
                method: .get, headers: [.authorization: "Bearer W"]
            ) { resp in #expect(resp.status == .forbidden) }
        }
    }

    /// GET .../maintenance/status: 実行前は running:false。実行中は registry.status(library:) と
    /// 同じ job/done/total/startedAt を返し、完了後は running:false に戻る
    /// （endpoint が actor の保持情報をそのまま運ぶことの確認）。
    @Test func statusEndpointMirrorsRegistryState() async throws {
        let fx = try TestLibraryFixture(name: "MSAdmin", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let core = makeCore(fixture: fx, adminTier: true)

        try await core.buildApplication().test(.router) { client in
            // 実行前
            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/maintenance/status",
                method: .get, headers: [.authorization: "Bearer W"]
            ) { resp in
                #expect(resp.status == .ok)
                let dto = try JSONDecoder().decode(MaintenanceStatusReply.self, from: Data(buffer: resp.body))
                #expect(dto == MaintenanceStatusReply(running: false))
            }

            // 実行中: registry を直接操作して進捗を作る（HTTP 経由の実ジョブはタイミング制御できないため、
            // registry の公開 API を直接叩いて GET が同じ値を返すかを検証する）。
            let gate = AsyncGate()
            let started = await core.maintenanceRegistry.start(library: lib.uuid, job: "full-scan") { progress, _ in
                progress(4, 10)
                await gate.wait()
                return 10
            }
            #expect(started == true)
            try await Task.sleep(for: .milliseconds(50))

            let direct = await core.maintenanceRegistry.status(library: lib.uuid)
            #expect(direct?.done == 4)
            #expect(direct?.total == 10)

            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/maintenance/status",
                method: .get, headers: [.authorization: "Bearer W"]
            ) { resp in
                #expect(resp.status == .ok)
                let dto = try JSONDecoder().decode(MaintenanceStatusReply.self, from: Data(buffer: resp.body))
                #expect(dto.running == true)
                #expect(dto.job == "full-scan")
                #expect(dto.done == direct?.done)
                #expect(dto.total == direct?.total)
                #expect(dto.startedAt == Int64(direct!.startedAt.timeIntervalSince1970))
            }

            await gate.open()
            try await Task.sleep(for: .milliseconds(50))

            try await client.execute(
                uri: "/api/v1/libraries/\(lib.uuid)/maintenance/status",
                method: .get, headers: [.authorization: "Bearer W"]
            ) { resp in
                #expect(resp.status == .ok)
                let dto = try JSONDecoder().decode(MaintenanceStatusReply.self, from: Data(buffer: resp.body))
                #expect(dto == MaintenanceStatusReply(running: false))
            }
        }
    }
}
