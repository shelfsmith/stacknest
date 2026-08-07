// SPDX-License-Identifier: MIT
import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import LibraryServerAPI
import LibraryStore
import AppCore
@testable import LibraryServer

/// Codex 事前レビュー Blocker2 の回帰テスト（`LibraryServer` 側の半分）。
///
/// **背景**: `ServerController`（共有ネットワークサーバ）は `LibraryServerCore` 構築時に
/// `maintenanceRegistry:` を渡していなかったため、`LibraryServerCore` が自前で別インスタンスを
/// 作ってしまい、`LocalControlController`（CLI/MCP・GUI 整合性チェックウィンドウ）と busy 判定が
/// 割れていた ―― 同じライブラリに対して共有サーバ経由とローカル経由の 2 本のフルスキャンが
/// 並走でき、一方が確定させた `damaged` を他方の遅れた `ok` が上書きしうる実害があった。
///
/// この回帰は本質的には `LibraryServer` の性質（**同じ `MaintenanceJobRegistry` インスタンスを
/// 注入された 2 個の独立した `LibraryServerCore` は busy 判定を共有する**）であり、
/// `SharedMaintenanceRegistry`（App target のプロセス内シングルトン）そのものには依存しない。
/// そのため、ここでは registry をこのテスト内でローカルに 1 個作り、`ServerController`/
/// `LocalControlController` 相当の 2 個の独立した core へ**同じインスタンス**を注入して検証する。
///
/// 「App 側の両コントローラが実際に `SharedMaintenanceRegistry.shared` を注入しているか」の
/// 配線検証（App test target は `HummingbirdTesting` を持たないため、実サーバは起動せず
/// identity 比較のみで行う）は `App/StackNestTests/SharedMaintenanceRegistryTests.swift` が
/// 別途担う。
@Suite("MaintenanceJobRegistry shared across independent LibraryServerCore instances (Codex pre-merge Blocker2)", .serialized)
struct MaintenanceRegistrySharedAcrossCoresTests {

    private func makeCore(fixture: TestLibraryFixture, registry: MaintenanceJobRegistry) -> LibraryServerCore {
        LibraryServerCore(
            config: .init(port: 0, token: "R", editToken: "W", adminTier: true),
            dataSource: StaticLibraryDataSource(libraries: [fixture.servedLibrary()]),
            maintenanceRegistry: registry)
    }

    private func postFullScan(
        _ client: some TestClientProtocol, uuid: String, mode: String
    ) async throws -> HTTPResponse.Status {
        let body = try JSONEncoder().encode(FullScanStartRequest(mode: mode))
        var status: HTTPResponse.Status = .internalServerError
        try await client.execute(
            uri: "/api/v1/libraries/\(uuid)/integrity/full-scan",
            method: .post,
            headers: [.authorization: "Bearer W", .contentType: "application/json"],
            body: .init(bytes: Array(body))
        ) { resp in status = resp.status }
        return status
    }

    /// 本命: 1 個目の core（ServerController 相当）経由で起動したジョブが、
    /// 2 個目の独立した core（LocalControlController 相当）経由の起動を 409 で拒否する ――
    /// ただし両者に**同一の** `MaintenanceJobRegistry` インスタンスを注入したときに限る。
    /// 修正前（`ServerController` 側だけ独自 registry を持つ状況を模した場合）なら、
    /// 2 個目の core は「running:false」を見て起動できてしまい、この期待は満たされない。
    @Test func startingThroughOneCoreBlocksTheOtherCoreWithConflict() async throws {
        let fx = try TestLibraryFixture(name: "SharedRegCross", bookCount: 0)
        defer { fx.cleanup() }
        let lib = fx.servedLibrary()
        let registry = MaintenanceJobRegistry(onProgress: { _, _, _, _ in }, onFinished: { _, _, _, _ in })
        let coreA = makeCore(fixture: fx, registry: registry)   // ServerController 相当
        let coreB = makeCore(fixture: fx, registry: registry)   // LocalControlController 相当

        // coreA/coreB は独立した LibraryServerCore インスタンスだが、同じ registry を
        // 注入されているため busy 判定を共有するはず。
        #expect(coreA.maintenanceRegistry === coreB.maintenanceRegistry,
                "両 core が同一の registry インスタンスを参照していない")

        // registry を直接占有して「実行中」を確定的に作る（実スキャンはタイミング制御できない
        // ため、既存の FullScanEndpointTests.secondStartWhileRunningReturnsConflict と同じ流儀）。
        let gate = AsyncGate()
        let started = await registry.start(library: lib.uuid, job: "full-scan") { progress, _ in
            progress(0, 1)
            await gate.wait()
            return 1
        }
        #expect(started == true)

        // coreA の HTTP 経由の POST は 409（自分自身の registry が busy）。
        try await coreA.buildApplication().test(.router) { client in
            let status = try await postFullScan(client, uuid: lib.uuid, mode: "unchecked")
            #expect(status == .conflict, "coreA 自身の視点でも busy のはず")
        }

        // coreB の HTTP 経由の POST も 409 でなければ、Blocker2 が再発している
        // （coreA が確定させる予定の結果を coreB が同時に上書きできてしまう状態）。
        try await coreB.buildApplication().test(.router) { client in
            let status = try await postFullScan(client, uuid: lib.uuid, mode: "unchecked")
            #expect(status == .conflict, "coreB が独自 registry を持っていると busy を見逃し 202 になる")
        }

        // 後片付け: 占有していたジョブを終わらせ、次のテストへ進む前に registry を idle に戻す。
        await gate.open()
        try await waitForMaintenanceJobToFinish(registry: registry, library: lib.uuid)
    }
}
