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

    /// レビュー指摘の回帰: run1 完了直後に同一 library で run2 が start された場合、run1 の
    /// 遅延 progress（finish(run1) より後にこの actor 上で実行される最後の progress(...)）が
    /// statuses[l] を run2 から run1 へ**取り違えて上書き**しないこと。
    ///
    /// **両方の run に同じ job 名（"full-scan"）を使う** ―― これが実運用（`full-scan` → cancel →
    /// `full-scan` の smoke 手順そのもの）であり、かつ Codex 事前レビューが指摘したとおり、
    /// ジョブ**名**で識別するガード（旧実装）はこのケースを検出できない（2 回とも同じ名前だと
    /// `statuses[l]?.job == j` が常に真になり、取り違えが起きても気づけない）。識別は実行ごとの
    /// 一意なトークンで行う（`MaintenanceJobRegistry.activeRun`）。
    ///
    /// `Task.sleep` による祈りではなく、run1 の `progress` クロージャを外へ捕捉して**呼ばずに**
    /// run(run1) を return させる（→ finish(run1) が確実に先に完了する）→ run2 を start する→
    /// その後で**明示的に**捕捉した run1 の progress を呼んで「遅れて届いた run1 の通知」を
    /// 再現する、という順序を onFinished/onProgress コールバック駆動の AsyncGate で強制する。
    @Test func staleProgressFromFinishedJobDoesNotOverwriteNewerJob() async throws {
        let jobName = "full-scan"
        nonisolated(unsafe) var capturedProgressRun1: (@Sendable (Int, Int) -> Void)?
        let run1Finished = AsyncGate()
        let lateProgressDelivered = AsyncGate()

        let reg = MaintenanceJobRegistry(
            onProgress: { l, j, d, t in
                if l == "L", j == jobName, d == 3, t == 3 {
                    Task { await lateProgressDelivered.open() }
                }
            },
            onFinished: { l, j, _, _ in
                if l == "L", j == jobName {
                    Task { await run1Finished.open() }
                }
            }
        )

        // run1: progress は「呼ばずに」参照だけ外へ捕捉し、即 return する
        // （= すぐ finish(run1) が走る。まだ捕捉した progress は一度も呼んでいない）。
        let startedRun1 = await reg.start(library: "L", job: jobName) { progress, _ in
            capturedProgressRun1 = progress
            return 1
        }
        #expect(startedRun1 == true)
        // onFinished(run1) の発火を待つ = finish(run1) 完了（running/statuses から run1 が消えた
        // こと）を確定させる。同じ Task 内で capturedProgressRun1 の代入 → run 完了 → finish の
        // 順に実行されるため、ここまで来れば代入は必ず完了している。
        await run1Finished.wait()
        let progressRun1 = try #require(capturedProgressRun1)
        let idleAfterRun1Finished = await reg.status(library: "L")
        #expect(idleAfterRun1Finished == nil)

        // run2 を同一 library・**同じ job 名**で start する（run1 は finish 済みなので busy に
        // ならない）。run2 は実際に進捗を報告し、その値が保持されることを後で確認する。
        let run2Gate = AsyncGate()
        let startedRun2 = await reg.start(library: "L", job: jobName) { progress, _ in
            progress(2, 5)
            await run2Gate.wait()
            return 5
        }
        #expect(startedRun2 == true)
        try await Task.sleep(for: .milliseconds(50))
        let statusAfterRun2Progress = await reg.status(library: "L")
        #expect(statusAfterRun2Progress?.job == jobName)
        #expect(statusAfterRun2Progress?.done == 2)
        #expect(statusAfterRun2Progress?.total == 5)

        // ここで「保留していた run1 の遅延 progress」を明示的に解放する（finish(run1) 後・
        // run2 実行中）。実行トークンでガードしていなければ、ジョブ名が両方とも "full-scan" で
        // 一致するため、この呼び出しが statuses["L"] を done:3, total:3（run1 の値）へ
        // 取り違えて上書きしてしまう。
        progressRun1(3, 3)
        await lateProgressDelivered.wait()

        let statusAfterLateProgress = await reg.status(library: "L")
        #expect(statusAfterLateProgress?.job == jobName)
        #expect(statusAfterLateProgress?.done == 2)
        #expect(statusAfterLateProgress?.total == 5)

        await run2Gate.open()
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
